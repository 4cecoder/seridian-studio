//! ALSA sequencer MIDI input (Linux only). Opens a client named "seridian",
//! creates one input port, and subscribes to every readable port of other
//! clients. `poll` is called from a non-audio thread; it pushes note events
//! into a NoteRing that the audio thread drains.
//!
//! libasound is declared with extern fn (no @cImport).

const std = @import("std");
const note_ring = @import("note_ring.zig");
const NoteRing = note_ring.NoteRing;

const log = std.log.scoped(.alsa_seq);

const SndSeq = opaque {};
const ClientInfo = opaque {};
const PortInfo = opaque {};

/// Mirrors snd_seq_event_t (28 bytes).
const SeqEvent = extern struct {
    type: u8,
    flags: u8,
    tag: i8,
    queue: u8,
    time: [2]u32,
    source_client: u8,
    source_port: u8,
    dest_client: u8,
    dest_port: u8,
    data: extern union {
        note: extern struct { channel: u8, note: u8, velocity: u8, off_velocity: u8, duration: u32 },
        raw: [3]u32,
    },
};
comptime {
    std.debug.assert(@sizeOf(SeqEvent) == 28);
}

extern "asound" fn snd_seq_open(handle: *?*SndSeq, name: [*:0]const u8, streams: c_int, mode: c_int) c_int;
extern "asound" fn snd_seq_close(handle: *SndSeq) c_int;
extern "asound" fn snd_seq_set_client_name(handle: *SndSeq, name: [*:0]const u8) c_int;
extern "asound" fn snd_seq_client_id(handle: *SndSeq) c_int;
extern "asound" fn snd_seq_create_simple_port(handle: *SndSeq, name: [*:0]const u8, caps: c_uint, ptype: c_uint) c_int;
extern "asound" fn snd_seq_connect_from(handle: *SndSeq, my_port: c_int, client: c_int, port: c_int) c_int;
extern "asound" fn snd_seq_disconnect_from(handle: *SndSeq, my_port: c_int, client: c_int, port: c_int) c_int;
extern "asound" fn snd_seq_event_input(handle: *SndSeq, ev: *?*SeqEvent) c_int;
extern "asound" fn snd_seq_client_info_malloc(ptr: *?*ClientInfo) c_int;
extern "asound" fn snd_seq_client_info_free(ptr: *ClientInfo) void;
extern "asound" fn snd_seq_client_info_set_client(info: *ClientInfo, client: c_int) void;
extern "asound" fn snd_seq_client_info_get_client(info: *const ClientInfo) c_int;
extern "asound" fn snd_seq_client_info_get_name(info: *const ClientInfo) [*:0]const u8;
extern "asound" fn snd_seq_query_next_client(handle: *SndSeq, info: *ClientInfo) c_int;
extern "asound" fn snd_seq_port_info_malloc(ptr: *?*PortInfo) c_int;
extern "asound" fn snd_seq_port_info_free(ptr: *PortInfo) void;
extern "asound" fn snd_seq_port_info_set_client(info: *PortInfo, client: c_int) void;
extern "asound" fn snd_seq_port_info_set_port(info: *PortInfo, port: c_int) void;
extern "asound" fn snd_seq_port_info_get_port(info: *const PortInfo) c_int;
extern "asound" fn snd_seq_port_info_get_capability(info: *const PortInfo) c_uint;
extern "asound" fn snd_seq_port_info_get_name(info: *const PortInfo) [*:0]const u8;
extern "asound" fn snd_seq_query_next_port(handle: *SndSeq, info: *PortInfo) c_int;
extern "c" fn usleep(usec: c_uint) c_int;

const SND_SEQ_OPEN_INPUT = 2;
const SND_SEQ_NONBLOCK = 1;
const SND_SEQ_PORT_CAP_READ = 1;
const SND_SEQ_PORT_CAP_WRITE = 2;
const SND_SEQ_PORT_CAP_SUBS_READ = 32;
const SND_SEQ_PORT_CAP_SUBS_WRITE = 64;
const SND_SEQ_PORT_TYPE_MIDI_GENERIC = 2;
const SND_SEQ_PORT_TYPE_APPLICATION = 1 << 20;
const SND_SEQ_CLIENT_SYSTEM = 0;
const SND_SEQ_EVENT_NOTEON = 6;
const SND_SEQ_EVENT_NOTEOFF = 7;
const EAGAIN = 11;

/// Maximum number of input ports tracked.
pub const MAX_INPUTS = 32;
pub const INPUT_NAME_CAPACITY = 96;
const POLL_INTERVAL_US = 1000;

/// One readable sequencer port.
pub const Input = struct {
    client: u8 = 0,
    port: u8 = 0,
    enabled: bool = false,
    name: [INPUT_NAME_CAPACITY]u8 = @splat(0),
};

/// Minimal spin lock for non-audio threads (std.Thread.Mutex is gone in this Zig).
/// Critical sections are short and never block (the sequencer is opened non-blocking).
const SpinLock = struct {
    locked: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    fn lock(self: *SpinLock) void {
        while (self.locked.cmpxchgWeak(false, true, .acquire, .monotonic) != null) {
            std.atomic.spinLoopHint();
        }
    }

    fn unlock(self: *SpinLock) void {
        self.locked.store(false, .release);
    }
};

pub const OpenError = error{ OpenFailed, PortFailed, OutOfMemory, ThreadFailed };

pub const AlsaSeq = struct {
    allocator: std.mem.Allocator,
    seq: *SndSeq,
    my_client: c_int,
    my_port: c_int,
    ring: *NoteRing,
    /// Guards `inputs`, `input_count` and all use of the `seq` handle (UI thread vs. poll thread).
    mutex: SpinLock = .{},
    inputs: [MAX_INPUTS]Input = @splat(.{}),
    input_count: usize = 0,
    running: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    thread: ?std.Thread = null,

    /// Open the sequencer, create the input port, subscribe to every readable port.
    /// `ring` must outlive the returned object. Does not start the poll thread.
    pub fn create(allocator: std.mem.Allocator, ring: *NoteRing) OpenError!*AlsaSeq {
        var handle: ?*SndSeq = null;
        if (snd_seq_open(&handle, "default", SND_SEQ_OPEN_INPUT, SND_SEQ_NONBLOCK) < 0) return error.OpenFailed;
        const seq = handle orelse return error.OpenFailed;
        errdefer _ = snd_seq_close(seq);
        if (snd_seq_set_client_name(seq, "seridian") < 0) return error.OpenFailed;
        const port = snd_seq_create_simple_port(
            seq,
            "input",
            SND_SEQ_PORT_CAP_WRITE | SND_SEQ_PORT_CAP_SUBS_WRITE,
            SND_SEQ_PORT_TYPE_MIDI_GENERIC | SND_SEQ_PORT_TYPE_APPLICATION,
        );
        if (port < 0) return error.PortFailed;

        const self = try allocator.create(AlsaSeq);
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .seq = seq,
            .my_client = snd_seq_client_id(seq),
            .my_port = port,
            .ring = ring,
        };
        self.refresh();
        return self;
    }

    /// Stop the poll thread, close the sequencer and free this object.
    pub fn destroy(self: *AlsaSeq) void {
        self.stopThread();
        _ = snd_seq_close(self.seq);
        self.allocator.destroy(self);
    }

    /// Start the background poll thread.
    pub fn startThread(self: *AlsaSeq) OpenError!void {
        if (self.thread != null) return;
        self.running.store(true, .release);
        self.thread = std.Thread.spawn(.{}, pollLoop, .{self}) catch {
            self.running.store(false, .release);
            return error.ThreadFailed;
        };
    }

    pub fn stopThread(self: *AlsaSeq) void {
        self.running.store(false, .release);
        if (self.thread) |t| t.join();
        self.thread = null;
    }

    fn pollLoop(self: *AlsaSeq) void {
        while (self.running.load(.acquire)) {
            self.poll();
            _ = usleep(POLL_INTERVAL_US);
        }
    }

    /// Enumerate readable ports of other clients. New ports are subscribed and
    /// enabled; ports already known keep their state; vanished ports are dropped.
    pub fn refresh(self: *AlsaSeq) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        var found: [MAX_INPUTS]Input = @splat(.{});
        var found_count: usize = 0;

        var cinfo_p: ?*ClientInfo = null;
        var pinfo_p: ?*PortInfo = null;
        if (snd_seq_client_info_malloc(&cinfo_p) < 0) return;
        const cinfo = cinfo_p orelse return;
        defer snd_seq_client_info_free(cinfo);
        if (snd_seq_port_info_malloc(&pinfo_p) < 0) return;
        const pinfo = pinfo_p orelse return;
        defer snd_seq_port_info_free(pinfo);

        snd_seq_client_info_set_client(cinfo, -1);
        while (snd_seq_query_next_client(self.seq, cinfo) >= 0) {
            const client = snd_seq_client_info_get_client(cinfo);
            if (client == SND_SEQ_CLIENT_SYSTEM or client == self.my_client) continue;
            snd_seq_port_info_set_client(pinfo, client);
            snd_seq_port_info_set_port(pinfo, -1);
            while (snd_seq_query_next_port(self.seq, pinfo) >= 0) {
                const want = SND_SEQ_PORT_CAP_READ | SND_SEQ_PORT_CAP_SUBS_READ;
                if (snd_seq_port_info_get_capability(pinfo) & want != want) continue;
                if (found_count >= MAX_INPUTS) break;
                const port = snd_seq_port_info_get_port(pinfo);
                if (client < 0 or client > 255 or port < 0 or port > 255) continue;
                var in: Input = .{ .client = @intCast(client), .port = @intCast(port) };
                writeName(&in.name, std.mem.span(snd_seq_client_info_get_name(cinfo)), std.mem.span(snd_seq_port_info_get_name(pinfo)));
                found[found_count] = in;
                found_count += 1;
            }
        }

        // Unsubscribe state is dropped with the vanished port by ALSA itself.
        for (found[0..found_count]) |*in| {
            if (self.findLocked(in.client, in.port)) |old| {
                in.enabled = old.enabled;
            } else {
                in.enabled = snd_seq_connect_from(self.seq, self.my_port, in.client, in.port) >= 0;
            }
        }
        self.inputs = found;
        self.input_count = found_count;
    }

    fn findLocked(self: *AlsaSeq, client: u8, port: u8) ?*Input {
        for (self.inputs[0..self.input_count]) |*in| {
            if (in.client == client and in.port == port) return in;
        }
        return null;
    }

    /// Number of known inputs (re-enumerates first so hot-plugged devices appear).
    pub fn count(self: *AlsaSeq) usize {
        self.refresh();
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.input_count;
    }

    /// Copy the display name of input `index` into `out` (NUL-terminated, truncated).
    /// Returns the name length, or null if out of range.
    pub fn copyName(self: *AlsaSeq, index: usize, out: []u8) ?usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (index >= self.input_count or out.len == 0) return null;
        const name = std.mem.sliceTo(&self.inputs[index].name, 0);
        const n = @min(name.len, out.len - 1);
        @memcpy(out[0..n], name[0..n]);
        out[n] = 0;
        return n;
    }

    /// Subscribe or unsubscribe input `index`. Returns false on bad index or ALSA failure.
    pub fn setEnabled(self: *AlsaSeq, index: usize, on: bool) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (index >= self.input_count) return false;
        const in = &self.inputs[index];
        if (in.enabled == on) return true;
        const rc = if (on)
            snd_seq_connect_from(self.seq, self.my_port, in.client, in.port)
        else
            snd_seq_disconnect_from(self.seq, self.my_port, in.client, in.port);
        if (rc < 0) return false;
        in.enabled = on;
        return true;
    }

    /// Drain pending sequencer events into the ring. Call from a non-audio thread.
    /// Note on with velocity 0 is a note off; everything else is ignored.
    pub fn poll(self: *AlsaSeq) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        while (true) {
            var ev: ?*SeqEvent = null;
            if (snd_seq_event_input(self.seq, &ev) < 0) return; // -EAGAIN: empty; others: overrun, retry next poll
            const e = ev orelse return;
            switch (e.type) {
                SND_SEQ_EVENT_NOTEON => {
                    const n = e.data.note;
                    _ = self.ring.push(.{ .note = n.note & 0x7f, .velocity = n.velocity & 0x7f, .on = n.velocity != 0 });
                },
                SND_SEQ_EVENT_NOTEOFF => {
                    const n = e.data.note;
                    _ = self.ring.push(.{ .note = n.note & 0x7f, .velocity = 0, .on = false });
                },
                else => {},
            }
        }
    }
};

fn writeName(out: *[INPUT_NAME_CAPACITY]u8, client: []const u8, port: []const u8) void {
    _ = std.fmt.bufPrint(out[0 .. INPUT_NAME_CAPACITY - 1], "{s}: {s}", .{ client, port }) catch |err| {
        log.warn("input name truncated: {}", .{err});
    };
}

test "AlsaSeq: event layout matches snd_seq_event_t" {
    try std.testing.expectEqual(@as(usize, 28), @sizeOf(SeqEvent));
    try std.testing.expectEqual(@as(usize, 16), @offsetOf(SeqEvent, "data"));
}
