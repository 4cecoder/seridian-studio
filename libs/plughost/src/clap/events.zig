// Translated to Zig from soundcraft/crates/clap-host/src/ffi/events.rs, soundcraft/crates/clap-host/src/ffi.rs (Copyright (c) 2026 ArtCraft Team and the SoundCraft contributors, MIT OR Apache-2.0). Modified by Seridian.
//! CLAP events and state streams for the host.
//!
//! - `InputEvents`: a preallocated, fixed-capacity list of CLAP events for one
//!   block, filled from the plug-0 `EventList` (sample offsets, sorted ascending).
//!   `fill` and the CLAP callbacks never allocate.
//! - `OutputEvents`: a preallocated list that keeps the parameter edits a plugin
//!   pushes back (typically GUI edits). `drain` hands them to the caller.
//! - `transportEvent`: the host transport as a CLAP transport event, in CLAP's
//!   fixed-point beat and second units.
//! - `istreamRead` / `ostreamWrite`: in-memory state streams. Reading is
//!   allocation-free. Writing allocates, so it runs on the control thread only
//!   (`save_state`), never inside `process`.
//!
//! Parameters are addressed by CLAP `clap_id` (u32). The caller builds the
//! dense-index to `clap_id` table once at init and passes it to `fill`.

const std = @import("std");
const testing = std.testing;
const abi = @import("abi.zig");
const host_event = @import("../event.zig");
const plugin = @import("../plugin.zig");

const Transport = plugin.Transport;

// ---- one event in CLAP form ------------------------------------------------------------------

/// A CLAP event as stored in an `InputEvents` buffer. Each variant starts with its
/// `clap_event_header`, so a pointer to the header is a pointer to the event.
pub const RawEvent = union(enum) {
    note: abi.ClapEventNote,
    param: abi.ClapEventParamValue,
    midi: abi.ClapEventMidi,

    pub fn header(self: *const RawEvent) *const abi.ClapEventHeader {
        return switch (self.*) {
            .note => |*e| &e.header,
            .param => |*e| &e.header,
            .midi => |*e| &e.header,
        };
    }
};

fn makeHeader(size: usize, type_: u16, time: u32) abi.ClapEventHeader {
    return .{
        .size = @intCast(size),
        .time = time,
        .space_id = abi.CLAP_CORE_EVENT_SPACE_ID,
        .type_ = type_,
        .flags = 0,
    };
}

/// Converts one host event to CLAP form. `base` is the sample offset the block
/// starts at (CLAP times are relative to it); offsets before `base` clamp to 0.
/// A parameter index outside `param_ids` gives null, so the event is dropped.
///
/// Velocity arrives as MIDI 0..127 and leaves as CLAP's normalised 0..1.
pub fn toRaw(ev: host_event.Event, base: u32, param_ids: []const abi.ClapId) ?RawEvent {
    const t = ev.offset -| base;
    return switch (ev.kind) {
        .note_on => |n| .{ .note = .{
            .header = makeHeader(@sizeOf(abi.ClapEventNote), abi.CLAP_EVENT_NOTE_ON, t),
            .note_id = -1,
            .port_index = 0,
            .channel = 0,
            .key = @as(i16, n.note),
            .velocity = @as(f64, @floatFromInt(n.velocity)) / 127.0,
        } },
        .note_off => |key| .{ .note = .{
            .header = makeHeader(@sizeOf(abi.ClapEventNote), abi.CLAP_EVENT_NOTE_OFF, t),
            .note_id = -1,
            .port_index = 0,
            .channel = 0,
            .key = @as(i16, key),
            .velocity = 0.0,
        } },
        .midi3 => |data| .{ .midi = .{
            .header = makeHeader(@sizeOf(abi.ClapEventMidi), abi.CLAP_EVENT_MIDI, t),
            .port_index = 0,
            .data = data,
        } },
        .param => |p| blk: {
            if (p.index >= param_ids.len) break :blk null;
            break :blk .{ .param = .{
                .header = makeHeader(@sizeOf(abi.ClapEventParamValue), abi.CLAP_EVENT_PARAM_VALUE, t),
                .param_id = param_ids[p.index],
                .cookie = null,
                .note_id = -1,
                .port_index = -1,
                .channel = -1,
                .key = -1,
                .value = @as(f64, p.value),
            } };
        },
    };
}

// ---- transport -------------------------------------------------------------------------------

/// CLAP fixed point: a non-finite position is 0, otherwise `round(x * factor)`,
/// saturating to i64 like Rust's `as i64`.
fn fixedPoint(x: f64, factor: i64) i64 {
    if (!std.math.isFinite(x)) return 0;
    return std.math.lossyCast(i64, @round(x * @as(f64, @floatFromInt(factor))));
}

/// The host transport as a CLAP transport event at time 0 of the block.
pub fn transportEvent(t: *const Transport) abi.ClapEventTransport {
    var flags: u32 = abi.CLAP_TRANSPORT_HAS_TEMPO |
        abi.CLAP_TRANSPORT_HAS_BEATS_TIMELINE |
        abi.CLAP_TRANSPORT_HAS_SECONDS_TIMELINE |
        abi.CLAP_TRANSPORT_HAS_TIME_SIGNATURE;
    if (t.playing) flags |= abi.CLAP_TRANSPORT_IS_PLAYING;
    if (t.recording) flags |= abi.CLAP_TRANSPORT_IS_RECORDING;
    return .{
        .header = makeHeader(@sizeOf(abi.ClapEventTransport), abi.CLAP_EVENT_TRANSPORT, 0),
        .flags = flags,
        .song_pos_beats = fixedPoint(t.quarters, abi.CLAP_BEATTIME_FACTOR),
        .song_pos_seconds = fixedPoint(t.seconds, abi.CLAP_SECTIME_FACTOR),
        .tempo = t.tempo,
        .tempo_inc = 0.0,
        .loop_start_beats = 0,
        .loop_end_beats = 0,
        .loop_start_seconds = 0,
        .loop_end_seconds = 0,
        .bar_start = fixedPoint(t.bar_start, abi.CLAP_BEATTIME_FACTOR),
        .bar_number = std.math.cast(i32, t.bar) orelse 0,
        .tsig_num = std.math.cast(u16, t.numerator) orelse 4,
        .tsig_denom = std.math.cast(u16, t.denominator) orelse 4,
    };
}

// ---- input events ----------------------------------------------------------------------------

/// The block's input events: a preallocated buffer of `RawEvent`s in offset order.
/// Storage is allocated by `init` and freed by `deinit`; `fill` never grows it.
pub const InputEvents = struct {
    buf: []RawEvent,
    len: usize = 0,

    /// Control thread (prepare). Allocates the storage once.
    pub fn init(gpa: std.mem.Allocator, capacity: usize) std.mem.Allocator.Error!InputEvents {
        return .{ .buf = try gpa.alloc(RawEvent, capacity) };
    }

    /// Control thread.
    pub fn deinit(self: *InputEvents, gpa: std.mem.Allocator) void {
        gpa.free(self.buf);
        self.* = .{ .buf = &.{} };
    }

    pub fn clear(self: *InputEvents) void {
        self.len = 0;
    }

    /// Audio thread safe. Replaces the contents with `src` converted for one block
    /// that starts at `base`. `src` must be sorted by offset, which the plug-0
    /// `EventList` guarantees, so the result is sorted too. Returns the number of
    /// events dropped (list full, or a parameter index outside `param_ids`).
    pub fn fill(self: *InputEvents, src: []const host_event.Event, param_ids: []const abi.ClapId, base: u32) usize {
        self.len = 0;
        var dropped: usize = 0;
        for (src) |ev| {
            if (self.len == self.buf.len) {
                dropped += 1;
                continue;
            }
            const raw = toRaw(ev, base, param_ids) orelse {
                dropped += 1;
                continue;
            };
            self.buf[self.len] = raw;
            self.len += 1;
        }
        return dropped;
    }

    /// The `clap_input_events` view of this list. The caller keeps `self` alive and
    /// unmoved for the whole `process` call.
    pub fn asClap(self: *InputEvents) abi.ClapInputEvents {
        return .{ .ctx = self, .size = inSize, .get = inGet };
    }
};

fn inputsOf(list: *const abi.ClapInputEvents) ?*const InputEvents {
    const ctx = list.ctx orelse return null;
    return @ptrCast(@alignCast(ctx));
}

fn inSize(list: *const abi.ClapInputEvents) callconv(.c) u32 {
    const self = inputsOf(list) orelse return 0;
    return std.math.cast(u32, self.len) orelse std.math.maxInt(u32);
}

fn inGet(list: *const abi.ClapInputEvents, index: u32) callconv(.c) ?*const abi.ClapEventHeader {
    const self = inputsOf(list) orelse return null;
    if (index >= self.len) return null;
    return self.buf[index].header();
}

// ---- output events ---------------------------------------------------------------------------

/// A parameter edit a plugin reported, addressed by CLAP id.
pub const ClapParamEdit = struct {
    param_id: abi.ClapId,
    value: f64,
};

/// The plugin's output: a preallocated list of parameter edits. Other event types
/// are ignored, and so are edits past the capacity, which is the same as the Rust
/// `out_params` Vec with `EVENT_CAP` slots.
pub const OutputEvents = struct {
    buf: []ClapParamEdit,
    len: usize = 0,

    /// Control thread. Allocates the storage once.
    pub fn init(gpa: std.mem.Allocator, capacity: usize) std.mem.Allocator.Error!OutputEvents {
        return .{ .buf = try gpa.alloc(ClapParamEdit, capacity) };
    }

    /// Control thread.
    pub fn deinit(self: *OutputEvents, gpa: std.mem.Allocator) void {
        gpa.free(self.buf);
        self.* = .{ .buf = &.{} };
    }

    pub fn clear(self: *OutputEvents) void {
        self.len = 0;
    }

    /// Takes the edits pushed since the last drain and empties the list. The slice
    /// points into the preallocated buffer and stays valid until the next push.
    pub fn drain(self: *OutputEvents) []const ClapParamEdit {
        const out = self.buf[0..self.len];
        self.len = 0;
        return out;
    }

    /// The `clap_output_events` view of this list.
    pub fn asClap(self: *OutputEvents) abi.ClapOutputEvents {
        return .{ .ctx = self, .try_push = outTryPush };
    }
};

fn outTryPush(list: *const abi.ClapOutputEvents, event: ?*const abi.ClapEventHeader) callconv(.c) bool {
    // Always report success: a refused event would make the plugin retry or fail.
    const ctx = list.ctx orelse return true;
    const self: *OutputEvents = @ptrCast(@alignCast(ctx));
    const h = event orelse return true;
    if (h.space_id != abi.CLAP_CORE_EVENT_SPACE_ID or
        h.type_ != abi.CLAP_EVENT_PARAM_VALUE or
        h.size < @sizeOf(abi.ClapEventParamValue)) return true;
    // The header says a complete clap_event_param_value follows. Plugins are not
    // required to align events to 8 bytes, so read it unaligned.
    const e = @as(*align(1) const abi.ClapEventParamValue, @ptrCast(h)).*;
    if (self.len < self.buf.len and std.math.isFinite(e.value)) {
        self.buf[self.len] = .{ .param_id = e.param_id, .value = e.value };
        self.len += 1;
    }
    return true;
}

// ---- state streams ---------------------------------------------------------------------------

/// Read side of an in-memory state blob, passed as the `ctx` of a `ClapIStream`.
pub const ReadCursor = struct {
    data: []const u8,
    pos: usize = 0,
};

/// `clap_istream.read`: copies at most `size` bytes from the cursor. Returns the
/// count copied, 0 at the end, or -1 for a null stream or buffer.
pub fn istreamRead(stream: *const abi.ClapIStream, buffer: ?*anyopaque, size: u64) callconv(.c) i64 {
    const dst = buffer orelse return -1;
    const ctx = stream.ctx orelse return -1;
    const cursor: *ReadCursor = @ptrCast(@alignCast(ctx));
    const rest = cursor.data[@min(cursor.pos, cursor.data.len)..];
    const want = std.math.cast(usize, size) orelse std.math.maxInt(usize);
    const n = @min(rest.len, want);
    const out: [*]u8 = @ptrCast(dst);
    @memcpy(out[0..n], rest[0..n]);
    cursor.pos += n;
    return std.math.cast(i64, n) orelse -1;
}

/// Write side of a save-state blob, passed as the `ctx` of a `ClapOStream`. Owns
/// its bytes; the allocation happens in `ostreamWrite`, so this is control-thread
/// only.
pub const WriteSink = struct {
    gpa: std.mem.Allocator,
    bytes: std.ArrayList(u8) = .empty,

    pub fn deinit(self: *WriteSink) void {
        self.bytes.deinit(self.gpa);
    }

    pub fn stream(self: *WriteSink) abi.ClapOStream {
        return .{ .ctx = self, .write = ostreamWrite };
    }
};

/// `clap_ostream.write`: appends `size` bytes. Refuses (-1) a null buffer, a
/// size past `MAX_STATE_BYTES` in total (checked before any byte is read), or an
/// allocation failure.
pub fn ostreamWrite(stream: *const abi.ClapOStream, buffer: ?*const anyopaque, size: u64) callconv(.c) i64 {
    const src_ptr = buffer orelse return -1;
    const ctx = stream.ctx orelse return -1;
    const sink: *WriteSink = @ptrCast(@alignCast(ctx));
    const n = std.math.cast(usize, size) orelse return -1;
    if (sink.bytes.items.len +| n > abi.MAX_STATE_BYTES) return -1;
    const src: [*]const u8 = @ptrCast(src_ptr);
    sink.bytes.appendSlice(sink.gpa, src[0..n]) catch return -1;
    return std.math.cast(i64, n) orelse -1;
}

// ---- tests -----------------------------------------------------------------------------------

test "the transport reaches clap in fixed point" {
    // ffi.rs `the_transport_reaches_clap_in_fixed_point`
    const t: Transport = .{
        .playing = true,
        .tempo = 90.0,
        .numerator = 3,
        .denominator = 4,
        .samples = 96_000,
        .seconds = 2.0,
        .quarters = 3.5,
        .bar_start = 3.0,
        .bar = 1,
    };
    const e = transportEvent(&t);
    try testing.expectEqual(abi.CLAP_EVENT_TRANSPORT, e.header.type_);
    try testing.expectEqual(@as(u32, @sizeOf(abi.ClapEventTransport)), e.header.size);
    try testing.expectEqual(abi.CLAP_TRANSPORT_IS_PLAYING, e.flags & abi.CLAP_TRANSPORT_IS_PLAYING);
    try testing.expectEqual(@as(u32, 0), e.flags & abi.CLAP_TRANSPORT_IS_RECORDING);
    try testing.expectEqual(7 * abi.CLAP_BEATTIME_FACTOR / 2, e.song_pos_beats);
    try testing.expectEqual(3 * abi.CLAP_BEATTIME_FACTOR, e.bar_start);
    try testing.expectEqual(2 * abi.CLAP_SECTIME_FACTOR, e.song_pos_seconds);
    try testing.expectEqual(@as(f64, 90.0), e.tempo);
    try testing.expectEqual(@as(i32, 1), e.bar_number);
    try testing.expectEqual(@as(u16, 3), e.tsig_num);
    try testing.expectEqual(@as(u16, 4), e.tsig_denom);

    var nan_t = t;
    nan_t.quarters = std.math.nan(f64);
    try testing.expectEqual(@as(i64, 0), transportEvent(&nan_t).song_pos_beats);
}

test "a stopped transport clears the playing and recording flags" {
    const t: Transport = .{ .playing = false, .recording = true };
    const e = transportEvent(&t);
    try testing.expectEqual(@as(u32, 0), e.flags & abi.CLAP_TRANSPORT_IS_PLAYING);
    try testing.expectEqual(abi.CLAP_TRANSPORT_IS_RECORDING, e.flags & abi.CLAP_TRANSPORT_IS_RECORDING);
    try testing.expect(e.flags & abi.CLAP_TRANSPORT_HAS_TEMPO != 0);
}

test "toRaw turns MIDI velocity into CLAP's 0..1 and times are block-relative" {
    const ev: host_event.Event = .{ .offset = 12, .kind = .{ .note_on = .{ .note = 60, .velocity = 127 } } };
    const raw = toRaw(ev, 4, &.{}).?;
    const h = raw.header().*;
    try testing.expectEqual(abi.CLAP_EVENT_NOTE_ON, h.type_);
    try testing.expectEqual(@as(u32, 8), h.time);
    try testing.expectEqual(@as(u32, @sizeOf(abi.ClapEventNote)), h.size);
    try testing.expectEqual(@as(f64, 1.0), raw.note.velocity);
    try testing.expectEqual(@as(i16, 60), raw.note.key);
    try testing.expectEqual(@as(i32, -1), raw.note.note_id);
}

test "toRaw clamps an offset before the block base to zero" {
    const ev: host_event.Event = .{ .offset = 2, .kind = .{ .note_off = 61 } };
    const raw = toRaw(ev, 10, &.{}).?;
    try testing.expectEqual(@as(u32, 0), raw.header().time);
    try testing.expectEqual(abi.CLAP_EVENT_NOTE_OFF, raw.header().type_);
    try testing.expectEqual(@as(f64, 0.0), raw.note.velocity);
}

test "toRaw maps a dense parameter index to its clap_id and drops unknown indices" {
    const ids = [_]abi.ClapId{ 1000, 2000 };
    const hit: host_event.Event = .{ .offset = 0, .kind = .{ .param = .{ .index = 1, .value = 0.25 } } };
    const raw = toRaw(hit, 0, &ids).?;
    try testing.expectEqual(abi.CLAP_EVENT_PARAM_VALUE, raw.header().type_);
    try testing.expectEqual(@as(abi.ClapId, 2000), raw.param.param_id);
    try testing.expectEqual(@as(f64, 0.25), raw.param.value);
    try testing.expect(raw.param.cookie == null);

    const miss: host_event.Event = .{ .offset = 0, .kind = .{ .param = .{ .index = 5, .value = 0.5 } } };
    try testing.expect(toRaw(miss, 0, &ids) == null);
}

test "InputEvents.fill keeps offset order, rebases times and counts drops" {
    var inputs = try InputEvents.init(testing.allocator, 3);
    defer inputs.deinit(testing.allocator);

    const ids = [_]abi.ClapId{77};
    const src = [_]host_event.Event{
        .{ .offset = 1, .kind = .{ .note_on = .{ .note = 60, .velocity = 100 } } },
        .{ .offset = 4, .kind = .{ .param = .{ .index = 0, .value = 1.0 } } },
        .{ .offset = 4, .kind = .{ .param = .{ .index = 9, .value = 0.0 } } }, // unknown index
        .{ .offset = 6, .kind = .{ .midi3 = .{ 0xB0, 1, 64 } } },
        .{ .offset = 9, .kind = .{ .note_off = 60 } }, // list is full by now
    };
    const dropped = inputs.fill(&src, &ids, 4);
    // The unknown parameter index and the event past the capacity are dropped.
    try testing.expectEqual(@as(usize, 2), dropped);
    try testing.expectEqual(@as(usize, 3), inputs.len);
    try testing.expectEqual(@as(u32, 0), inputs.buf[0].header().time);
    try testing.expectEqual(@as(u32, 0), inputs.buf[1].header().time);
    try testing.expectEqual(@as(u32, 2), inputs.buf[2].header().time);
    try testing.expectEqual(abi.CLAP_EVENT_NOTE_ON, inputs.buf[0].header().type_);
    try testing.expectEqual(abi.CLAP_EVENT_PARAM_VALUE, inputs.buf[1].header().type_);
    try testing.expectEqual(abi.CLAP_EVENT_MIDI, inputs.buf[2].header().type_);

    inputs.clear();
    try testing.expectEqual(@as(usize, 0), inputs.len);
}

test "InputEvents exposes the block through the CLAP callbacks" {
    var inputs = try InputEvents.init(testing.allocator, 4);
    defer inputs.deinit(testing.allocator);

    const src = [_]host_event.Event{
        .{ .offset = 2, .kind = .{ .note_off = 60 } },
        .{ .offset = 9, .kind = .{ .midi3 = .{ 0xB0, 1, 64 } } },
    };
    try testing.expectEqual(@as(usize, 0), inputs.fill(&src, &.{}, 0));
    const iface = inputs.asClap();
    try testing.expectEqual(@as(u32, 2), iface.size.?(&iface));
    const h0 = iface.get.?(&iface, 0).?;
    try testing.expectEqual(abi.CLAP_EVENT_NOTE_OFF, h0.type_);
    try testing.expectEqual(@as(u32, 2), h0.time);
    try testing.expectEqual(@as(u32, 9), iface.get.?(&iface, 1).?.time);
    try testing.expect(iface.get.?(&iface, 2) == null);
}

test "InputEvents with a null context reports no events" {
    const iface: abi.ClapInputEvents = .{ .ctx = null, .size = inSize, .get = inGet };
    try testing.expectEqual(@as(u32, 0), iface.size.?(&iface));
    try testing.expect(iface.get.?(&iface, 0) == null);
}

test "OutputEvents keeps finite parameter edits and ignores everything else" {
    var out = try OutputEvents.init(testing.allocator, 2);
    defer out.deinit(testing.allocator);
    const iface = out.asClap();

    var pv: abi.ClapEventParamValue = .{
        .header = .{
            .size = @sizeOf(abi.ClapEventParamValue),
            .time = 0,
            .space_id = abi.CLAP_CORE_EVENT_SPACE_ID,
            .type_ = abi.CLAP_EVENT_PARAM_VALUE,
            .flags = 0,
        },
        .param_id = 7,
        .cookie = null,
        .note_id = -1,
        .port_index = -1,
        .channel = -1,
        .key = -1,
        .value = 0.5,
    };
    try testing.expect(iface.try_push.?(&iface, &pv.header));

    // A non-finite value is accepted by the call but not kept.
    pv.value = std.math.nan(f64);
    try testing.expect(iface.try_push.?(&iface, &pv.header));
    pv.value = 0.5;

    // Another event type is ignored.
    pv.header.type_ = abi.CLAP_EVENT_NOTE_ON;
    try testing.expect(iface.try_push.?(&iface, &pv.header));
    pv.header.type_ = abi.CLAP_EVENT_PARAM_VALUE;

    // A header too short for a param value is ignored.
    pv.header.size = 8;
    try testing.expect(iface.try_push.?(&iface, &pv.header));
    pv.header.size = @sizeOf(abi.ClapEventParamValue);

    const edits = out.drain();
    try testing.expectEqual(@as(usize, 1), edits.len);
    try testing.expectEqual(@as(abi.ClapId, 7), edits[0].param_id);
    try testing.expectEqual(@as(f64, 0.5), edits[0].value);
    try testing.expectEqual(@as(usize, 0), out.drain().len);
}

test "OutputEvents stops keeping edits at capacity but still reports success" {
    var out = try OutputEvents.init(testing.allocator, 1);
    defer out.deinit(testing.allocator);
    const iface = out.asClap();

    var pv: abi.ClapEventParamValue = std.mem.zeroes(abi.ClapEventParamValue);
    pv.header.size = @sizeOf(abi.ClapEventParamValue);
    pv.header.type_ = abi.CLAP_EVENT_PARAM_VALUE;
    pv.param_id = 1;
    pv.value = 0.1;
    try testing.expect(iface.try_push.?(&iface, &pv.header));
    pv.param_id = 2;
    try testing.expect(iface.try_push.?(&iface, &pv.header));
    try testing.expectEqual(@as(usize, 1), out.drain().len);
}

test "istreamRead copies at most size bytes and then reports end of stream" {
    var cursor = ReadCursor{ .data = "abcdef" };
    const s: abi.ClapIStream = .{ .ctx = &cursor, .read = istreamRead };
    var first: [4]u8 = undefined;
    try testing.expectEqual(@as(i64, 4), s.read.?(&s, &first, first.len));
    try testing.expectEqualStrings("abcd", first[0..]);
    var rest: [4]u8 = undefined;
    try testing.expectEqual(@as(i64, 2), s.read.?(&s, &rest, rest.len));
    try testing.expectEqualStrings("ef", rest[0..2]);
    try testing.expectEqual(@as(i64, 0), s.read.?(&s, &rest, rest.len));
    try testing.expectEqual(@as(i64, -1), s.read.?(&s, null, 4));
}

test "ostreamWrite appends bytes and refuses writes past the state cap" {
    var sink = WriteSink{ .gpa = testing.allocator };
    defer sink.deinit();
    const s = sink.stream();
    const data = "state";
    try testing.expectEqual(@as(i64, 5), s.write.?(&s, data.ptr, 5));
    try testing.expectEqualStrings("state", sink.bytes.items);

    // Refused before any byte is read, so the buffer pointer is never dereferenced.
    try testing.expectEqual(@as(i64, -1), s.write.?(&s, data.ptr, abi.MAX_STATE_BYTES));
    try testing.expectEqual(@as(i64, -1), s.write.?(&s, null, 1));
    try testing.expectEqual(@as(usize, 5), sink.bytes.items.len);
}
