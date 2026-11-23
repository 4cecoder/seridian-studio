const std = @import("std");
const builtin = @import("builtin");

const log = std.log.scoped(.coremidi);

// CoreMIDI types via extern declarations
// Avoids @cImport issues with Apple headers

pub const MIDIClientRef = u32;
pub const MIDIPortRef = u32;
pub const MIDIEndpointRef = u32;
pub const MIDIObjectRef = u32;
pub const OSStatus = i32;
pub const ItemCount = usize;

pub const MIDIPacket = extern struct {
    timeStamp: u64,
    length: u16,
    data: [256]u8,
};

pub const MIDIPacketList = extern struct {
    numPackets: u32,
    packet: [1]MIDIPacket,
};

// CoreMIDI declares MIDIPacketList and MIDIPacket with `#pragma pack(4)`, so
// their in-memory layout differs from the naturally aligned extern structs
// above: walk received lists byte-wise with these offsets instead.
const packet_list_header_size = 4; // numPackets
const packet_header_size = 10; // timeStamp + length

/// Offset of the packet after the one at `off` (MIDIPacketNext): arm64 rounds
/// up to 4 bytes, x86_64 packs packets back to back.
fn packetListNextOffset(off: usize, length: usize) usize {
    const end = off + packet_header_size + length;
    return if (builtin.cpu.arch == .aarch64) std.mem.alignForward(usize, end, 4) else end;
}

// CoreMIDI constants
pub const noErr: OSStatus = 0;

// MIDI message types
pub const MIDIMessageType = enum(u8) {
    note_off = 0x80,
    note_on = 0x90,
    poly_pressure = 0xA0,
    control_change = 0xB0,
    program_change = 0xC0,
    channel_pressure = 0xD0,
    pitch_bend = 0xE0,
    system = 0xF0,
};

// Parsed MIDI event
pub const MIDIEvent = struct {
    timestamp: u64,
    channel: u4,
    message: union(enum) {
        note_on: struct { note: u7, velocity: u7 },
        note_off: struct { note: u7, velocity: u7 },
        control_change: struct { controller: u7, value: u7 },
        program_change: struct { program: u7 },
        pitch_bend: struct { value: i16 },
        other: struct { status: u8, data: []const u8 },
    },
};

// CoreMIDI function declarations (linked via CoreMIDI framework)
/// macOS framework entry points. Other platforms get stubs that are never
/// reached (callers check the OS first) so the build still links.
pub const os_api = if (builtin.os.tag == .macos) struct {
    pub extern fn MIDIClientCreate(
        name: *const anyopaque, // CFStringRef
        notifyProc: ?*const anyopaque,
        notifyRefCon: ?*anyopaque,
        outClient: *MIDIClientRef,
    ) OSStatus;
    pub extern fn MIDIClientDispose(client: MIDIClientRef) OSStatus;
    pub extern fn MIDIInputPortCreate(
        client: MIDIClientRef,
        portName: *const anyopaque, // CFStringRef
        readProc: *const fn (pktlist: *const anyopaque, readProcRefCon: ?*anyopaque, srcConnRefCon: ?*anyopaque) callconv(.c) void,
        refCon: ?*anyopaque,
        outPort: *MIDIPortRef,
    ) OSStatus;
    pub extern fn MIDIOutputPortCreate(
        client: MIDIClientRef,
        portName: *const anyopaque, // CFStringRef
        outPort: *MIDIPortRef,
    ) OSStatus;
    pub extern fn MIDIPortDispose(port: MIDIPortRef) OSStatus;
    pub extern fn MIDIPortConnectSource(
        port: MIDIPortRef,
        source: MIDIEndpointRef,
        connRefCon: ?*anyopaque,
    ) OSStatus;
    pub extern fn MIDIPortDisconnectSource(port: MIDIPortRef, source: MIDIEndpointRef) OSStatus;
    pub extern fn MIDIGetNumberOfSources() ItemCount;
    pub extern fn MIDIGetSource(sourceIndex0: ItemCount) MIDIEndpointRef;
    pub extern fn MIDIGetNumberOfDestinations() ItemCount;
    pub extern fn MIDIGetDestination(destIndex0: ItemCount) MIDIEndpointRef;
    pub extern fn MIDISend(port: MIDIPortRef, dest: MIDIEndpointRef, pktlist: *const MIDIPacketList) OSStatus;
    pub extern fn CFStringCreateWithCString(
        alloc: ?*anyopaque,
        cStr: [*:0]const u8,
        encoding: u32,
    ) ?*anyopaque;
    pub extern fn CFRelease(cf: *anyopaque) void;
} else struct {
    pub fn MIDIClientCreate(_: *const anyopaque, _: ?*const anyopaque, _: ?*anyopaque, _: *MIDIClientRef) OSStatus {
        @panic("MIDIClientCreate is only available on macOS");
    }
    pub fn MIDIClientDispose(_: MIDIClientRef) OSStatus {
        @panic("MIDIClientDispose is only available on macOS");
    }
    pub fn MIDIInputPortCreate(_: MIDIClientRef, _: *const anyopaque, _: *const fn (*const anyopaque, ?*anyopaque, ?*anyopaque) callconv(.c) void, _: ?*anyopaque, _: *MIDIPortRef) OSStatus {
        @panic("MIDIInputPortCreate is only available on macOS");
    }
    pub fn MIDIOutputPortCreate(_: MIDIClientRef, _: *const anyopaque, _: *MIDIPortRef) OSStatus {
        @panic("MIDIOutputPortCreate is only available on macOS");
    }
    pub fn MIDIPortDispose(_: MIDIPortRef) OSStatus {
        @panic("MIDIPortDispose is only available on macOS");
    }
    pub fn MIDIPortConnectSource(_: MIDIPortRef, _: MIDIEndpointRef, _: ?*anyopaque) OSStatus {
        @panic("MIDIPortConnectSource is only available on macOS");
    }
    pub fn MIDIPortDisconnectSource(_: MIDIPortRef, _: MIDIEndpointRef) OSStatus {
        @panic("MIDIPortDisconnectSource is only available on macOS");
    }
    pub fn MIDIGetNumberOfSources() ItemCount {
        @panic("MIDIGetNumberOfSources is only available on macOS");
    }
    pub fn MIDIGetSource(_: ItemCount) MIDIEndpointRef {
        @panic("MIDIGetSource is only available on macOS");
    }
    pub fn MIDIGetNumberOfDestinations() ItemCount {
        @panic("MIDIGetNumberOfDestinations is only available on macOS");
    }
    pub fn MIDIGetDestination(_: ItemCount) MIDIEndpointRef {
        @panic("MIDIGetDestination is only available on macOS");
    }
    pub fn MIDISend(_: MIDIPortRef, _: MIDIEndpointRef, _: *const MIDIPacketList) OSStatus {
        @panic("MIDISend is only available on macOS");
    }
    pub fn CFStringCreateWithCString(_: ?*anyopaque, _: [*:0]const u8, _: u32) ?*anyopaque {
        @panic("CFStringCreateWithCString is only available on macOS");
    }
    pub fn CFRelease(_: *anyopaque) void {
        @panic("CFRelease is only available on macOS");
    }
};

// CoreFoundation for CFString

const kCFStringEncodingUTF8: u32 = 0x08000100;

pub const CoreMIDIBackend = struct {
    const MAX_SOURCES = 16;
    const MAX_EVENTS = 256;

    allocator: std.mem.Allocator,
    client: MIDIClientRef = 0,
    input_port: MIDIPortRef = 0,
    output_port: MIDIPortRef = 0,

    // Connected sources (fixed size array)
    connected_sources: [MAX_SOURCES]MIDIEndpointRef = @as([MAX_SOURCES]MIDIEndpointRef, @splat(0)),
    connected_count: usize = 0,

    // Callback for received MIDI events
    event_callback: ?*const fn (event: MIDIEvent, user_data: ?*anyopaque) void = null,
    callback_user_data: ?*anyopaque = null,

    // Event queue for thread-safe access (ring buffer)
    event_queue: [MAX_EVENTS]MIDIEvent = undefined,
    queue_head: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    queue_tail: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),

    pub fn init(allocator: std.mem.Allocator) !CoreMIDIBackend {
        if (builtin.os.tag != .macos) {
            return error.UnsupportedPlatform;
        }

        log.info("Initializing CoreMIDI backend", .{});

        var self = CoreMIDIBackend{
            .allocator = allocator,
        };

        // Create MIDI client
        const client_name = os_api.CFStringCreateWithCString(null, "DAW MIDI Client", kCFStringEncodingUTF8) orelse {
            log.err("Failed to create client name string", .{});
            return error.CoreMIDIInitFailed;
        };
        defer os_api.CFRelease(client_name);

        var status = os_api.MIDIClientCreate(client_name, null, null, &self.client);
        if (status != noErr) {
            log.err("Failed to create MIDI client: {d}", .{status});
            return error.CoreMIDIInitFailed;
        }
        errdefer _ = os_api.MIDIClientDispose(self.client);

        // Create input port
        const input_name = os_api.CFStringCreateWithCString(null, "DAW MIDI In", kCFStringEncodingUTF8) orelse {
            return error.CoreMIDIInitFailed;
        };
        defer os_api.CFRelease(input_name);

        status = os_api.MIDIInputPortCreate(self.client, input_name, midiReadCallback, null, &self.input_port);
        if (status != noErr) {
            log.err("Failed to create MIDI input port: {d}", .{status});
            return error.CoreMIDIInitFailed;
        }

        // Create output port
        const output_name = os_api.CFStringCreateWithCString(null, "DAW MIDI Out", kCFStringEncodingUTF8) orelse {
            return error.CoreMIDIInitFailed;
        };
        defer os_api.CFRelease(output_name);

        status = os_api.MIDIOutputPortCreate(self.client, output_name, &self.output_port);
        if (status != noErr) {
            log.err("Failed to create MIDI output port: {d}", .{status});
            return error.CoreMIDIInitFailed;
        }

        const num_sources = os_api.MIDIGetNumberOfSources();
        const num_dests = os_api.MIDIGetNumberOfDestinations();
        log.info("CoreMIDI initialized: {d} sources, {d} destinations", .{ num_sources, num_dests });

        return self;
    }

    pub fn deinit(self: *CoreMIDIBackend) void {
        if (builtin.os.tag != .macos) return;

        // Disconnect all sources
        for (0..self.connected_count) |i| {
            _ = os_api.MIDIPortDisconnectSource(self.input_port, self.connected_sources[i]);
        }

        // Dispose ports and client
        if (self.input_port != 0) {
            _ = os_api.MIDIPortDispose(self.input_port);
        }
        if (self.output_port != 0) {
            _ = os_api.MIDIPortDispose(self.output_port);
        }
        if (self.client != 0) {
            _ = os_api.MIDIClientDispose(self.client);
        }

        log.info("CoreMIDI backend shut down", .{});
    }

    /// Connect to all available MIDI sources
    pub fn connectAllSources(self: *CoreMIDIBackend) !void {
        const num_sources = os_api.MIDIGetNumberOfSources();
        for (0..num_sources) |i| {
            if (self.connected_count >= MAX_SOURCES) break;
            const source = os_api.MIDIGetSource(i);
            if (source != 0) {
                const status = os_api.MIDIPortConnectSource(self.input_port, source, self);
                if (status == noErr) {
                    self.connected_sources[self.connected_count] = source;
                    self.connected_count += 1;
                    log.info("Connected to MIDI source {d}", .{i});
                }
            }
        }
    }

    /// Connect to a specific MIDI source by index
    pub fn connectSource(self: *CoreMIDIBackend, index: usize) !void {
        if (self.connected_count >= MAX_SOURCES) return error.TooManySources;

        const source = os_api.MIDIGetSource(index);
        if (source == 0) return error.InvalidMIDISource;

        const status = os_api.MIDIPortConnectSource(self.input_port, source, self);
        if (status != noErr) {
            return error.MIDIConnectionFailed;
        }
        self.connected_sources[self.connected_count] = source;
        self.connected_count += 1;
    }

    /// Get number of available MIDI sources
    pub fn getSourceCount() usize {
        if (builtin.os.tag != .macos) return 0;
        return os_api.MIDIGetNumberOfSources();
    }

    /// Get number of available MIDI destinations
    pub fn getDestinationCount() usize {
        if (builtin.os.tag != .macos) return 0;
        return os_api.MIDIGetNumberOfDestinations();
    }

    /// Set callback for MIDI events
    pub fn setEventCallback(
        self: *CoreMIDIBackend,
        callback: *const fn (event: MIDIEvent, user_data: ?*anyopaque) void,
        user_data: ?*anyopaque,
    ) void {
        self.event_callback = callback;
        self.callback_user_data = user_data;
    }

    /// Poll for queued MIDI events (thread-safe, lock-free ring buffer)
    pub fn pollEvents(self: *CoreMIDIBackend, buffer: []MIDIEvent) usize {
        var count: usize = 0;
        const tail = self.queue_tail.load(.acquire);

        while (count < buffer.len) {
            const head = self.queue_head.load(.acquire);
            if (head == tail) break; // Queue empty

            buffer[count] = self.event_queue[head];
            count += 1;

            // Advance head
            const new_head = (head + 1) % MAX_EVENTS;
            self.queue_head.store(new_head, .release);
        }
        return count;
    }

    /// Queue an event (called from MIDI callback thread)
    fn queueEvent(self: *CoreMIDIBackend, event: MIDIEvent) void {
        const tail = self.queue_tail.load(.acquire);
        const next_tail = (tail + 1) % MAX_EVENTS;
        const head = self.queue_head.load(.acquire);

        // Check if queue is full
        if (next_tail == head) return; // Drop event

        self.event_queue[tail] = event;
        self.queue_tail.store(next_tail, .release);
    }

    /// Send a MIDI note on message
    pub fn sendNoteOn(self: *CoreMIDIBackend, dest_index: usize, channel: u4, note: u7, velocity: u7) !void {
        const dest = os_api.MIDIGetDestination(dest_index);
        if (dest == 0) return error.InvalidMIDIDestination;

        var packet_list: MIDIPacketList = undefined;
        packet_list.numPackets = 1;
        packet_list.packet[0].timeStamp = 0;
        packet_list.packet[0].length = 3;
        packet_list.packet[0].data[0] = 0x90 | @as(u8, channel);
        packet_list.packet[0].data[1] = note;
        packet_list.packet[0].data[2] = velocity;

        const status = os_api.MIDISend(self.output_port, dest, &packet_list);
        if (status != noErr) {
            return error.MIDISendFailed;
        }
    }

    /// Send a MIDI note off message
    pub fn sendNoteOff(self: *CoreMIDIBackend, dest_index: usize, channel: u4, note: u7, velocity: u7) !void {
        const dest = os_api.MIDIGetDestination(dest_index);
        if (dest == 0) return error.InvalidMIDIDestination;

        var packet_list: MIDIPacketList = undefined;
        packet_list.numPackets = 1;
        packet_list.packet[0].timeStamp = 0;
        packet_list.packet[0].length = 3;
        packet_list.packet[0].data[0] = 0x80 | @as(u8, channel);
        packet_list.packet[0].data[1] = note;
        packet_list.packet[0].data[2] = velocity;

        const status = os_api.MIDISend(self.output_port, dest, &packet_list);
        if (status != noErr) {
            return error.MIDISendFailed;
        }
    }

    // Internal MIDI read callback (called from CoreMIDI thread). The backend
    // comes from the source connection refCon: connectSource runs once the
    // backend is at its final address, unlike init, which returns by value.
    fn midiReadCallback(
        pktlist: *const anyopaque,
        _: ?*anyopaque,
        srcConnRefCon: ?*anyopaque,
    ) callconv(.c) void {
        const self: *CoreMIDIBackend = @ptrCast(@alignCast(srcConnRefCon orelse return));

        const bytes: [*]const u8 = @ptrCast(pktlist);
        const num_packets = std.mem.readInt(u32, bytes[0..4], .little);
        var off: usize = packet_list_header_size;
        for (0..num_packets) |_| {
            var packet: MIDIPacket = undefined;
            packet.timeStamp = std.mem.readInt(u64, bytes[off..][0..8], .little);
            packet.length = std.mem.readInt(u16, bytes[off + 8 ..][0..2], .little);
            const len = @min(packet.length, packet.data.len);
            @memcpy(packet.data[0..len], bytes[off + packet_header_size ..][0..len]);

            if (parseMIDIPacket(&packet)) |event| {
                // Call immediate callback if set
                if (self.event_callback) |cb| {
                    cb(event, self.callback_user_data);
                }

                // Queue for polling (lock-free)
                self.queueEvent(event);
            }

            off = packetListNextOffset(off, packet.length);
        }
    }

    fn parseMIDIPacket(packet: *const MIDIPacket) ?MIDIEvent {
        if (packet.length == 0) return null;

        const status = packet.data[0];
        const msg_type = status & 0xF0;
        const channel: u4 = @truncate(status & 0x0F);

        var event = MIDIEvent{
            .timestamp = packet.timeStamp,
            .channel = channel,
            .message = undefined,
        };

        switch (msg_type) {
            0x90 => { // Note On
                if (packet.length >= 3) {
                    const velocity: u7 = @truncate(packet.data[2] & 0x7F);
                    if (velocity == 0) {
                        // Note On with velocity 0 is Note Off
                        event.message = .{ .note_off = .{
                            .note = @truncate(packet.data[1] & 0x7F),
                            .velocity = 0,
                        } };
                    } else {
                        event.message = .{ .note_on = .{
                            .note = @truncate(packet.data[1] & 0x7F),
                            .velocity = velocity,
                        } };
                    }
                    return event;
                }
            },
            0x80 => { // Note Off
                if (packet.length >= 3) {
                    event.message = .{ .note_off = .{
                        .note = @truncate(packet.data[1] & 0x7F),
                        .velocity = @truncate(packet.data[2] & 0x7F),
                    } };
                    return event;
                }
            },
            0xB0 => { // Control Change
                if (packet.length >= 3) {
                    event.message = .{ .control_change = .{
                        .controller = @truncate(packet.data[1] & 0x7F),
                        .value = @truncate(packet.data[2] & 0x7F),
                    } };
                    return event;
                }
            },
            0xC0 => { // Program Change
                if (packet.length >= 2) {
                    event.message = .{ .program_change = .{
                        .program = @truncate(packet.data[1] & 0x7F),
                    } };
                    return event;
                }
            },
            0xE0 => { // Pitch Bend
                if (packet.length >= 3) {
                    const lsb: i16 = @as(i16, packet.data[1] & 0x7F);
                    const msb: i16 = @as(i16, packet.data[2] & 0x7F);
                    const raw_value: i16 = (msb << 7) | lsb;
                    event.message = .{ .pitch_bend = .{
                        .value = raw_value - 8192,
                    } };
                    return event;
                }
            },
            else => {},
        }

        return null;
    }
};

/// Check if CoreMIDI is available
pub fn detectCoreMIDI() bool {
    return builtin.os.tag == .macos;
}

// ============================================================================
// Tests
// ============================================================================

test "parseMIDIPacket - note on message" {
    var packet = MIDIPacket{
        .timeStamp = 1234567890,
        .length = 3,
        .data = @as([256]u8, @splat(0)),
    };

    // Note On: status 0x90 (channel 0), note 60 (Middle C), velocity 100
    packet.data[0] = 0x90;
    packet.data[1] = 60;
    packet.data[2] = 100;

    const event = CoreMIDIBackend.parseMIDIPacket(&packet);
    try std.testing.expect(event != null);

    const evt = event.?;
    try std.testing.expectEqual(@as(u64, 1234567890), evt.timestamp);
    try std.testing.expectEqual(@as(u4, 0), evt.channel);

    switch (evt.message) {
        .note_on => |note_on| {
            try std.testing.expectEqual(@as(u7, 60), note_on.note);
            try std.testing.expectEqual(@as(u7, 100), note_on.velocity);
        },
        else => try std.testing.expect(false), // Should be note_on
    }
}

test "parseMIDIPacket - note on with different channel" {
    var packet = MIDIPacket{
        .timeStamp = 0,
        .length = 3,
        .data = @as([256]u8, @splat(0)),
    };

    // Note On: status 0x95 (channel 5), note 72, velocity 127
    packet.data[0] = 0x95;
    packet.data[1] = 72;
    packet.data[2] = 127;

    const event = CoreMIDIBackend.parseMIDIPacket(&packet);
    try std.testing.expect(event != null);

    const evt = event.?;
    try std.testing.expectEqual(@as(u4, 5), evt.channel);

    switch (evt.message) {
        .note_on => |note_on| {
            try std.testing.expectEqual(@as(u7, 72), note_on.note);
            try std.testing.expectEqual(@as(u7, 127), note_on.velocity);
        },
        else => try std.testing.expect(false),
    }
}

test "parseMIDIPacket - note on with velocity 0 becomes note off" {
    var packet = MIDIPacket{
        .timeStamp = 0,
        .length = 3,
        .data = @as([256]u8, @splat(0)),
    };

    // Note On with velocity 0 should be treated as Note Off
    packet.data[0] = 0x90;
    packet.data[1] = 60;
    packet.data[2] = 0;

    const event = CoreMIDIBackend.parseMIDIPacket(&packet);
    try std.testing.expect(event != null);

    const evt = event.?;
    switch (evt.message) {
        .note_off => |note_off| {
            try std.testing.expectEqual(@as(u7, 60), note_off.note);
            try std.testing.expectEqual(@as(u7, 0), note_off.velocity);
        },
        else => try std.testing.expect(false), // Should be note_off
    }
}

test "parseMIDIPacket - note off message" {
    var packet = MIDIPacket{
        .timeStamp = 9876543210,
        .length = 3,
        .data = @as([256]u8, @splat(0)),
    };

    // Note Off: status 0x80 (channel 0), note 60, velocity 64
    packet.data[0] = 0x80;
    packet.data[1] = 60;
    packet.data[2] = 64;

    const event = CoreMIDIBackend.parseMIDIPacket(&packet);
    try std.testing.expect(event != null);

    const evt = event.?;
    try std.testing.expectEqual(@as(u64, 9876543210), evt.timestamp);
    try std.testing.expectEqual(@as(u4, 0), evt.channel);

    switch (evt.message) {
        .note_off => |note_off| {
            try std.testing.expectEqual(@as(u7, 60), note_off.note);
            try std.testing.expectEqual(@as(u7, 64), note_off.velocity);
        },
        else => try std.testing.expect(false),
    }
}

test "parseMIDIPacket - control change message" {
    var packet = MIDIPacket{
        .timeStamp = 0,
        .length = 3,
        .data = @as([256]u8, @splat(0)),
    };

    // Control Change: status 0xB0 (channel 0), controller 7 (volume), value 100
    packet.data[0] = 0xB0;
    packet.data[1] = 7;
    packet.data[2] = 100;

    const event = CoreMIDIBackend.parseMIDIPacket(&packet);
    try std.testing.expect(event != null);

    const evt = event.?;
    try std.testing.expectEqual(@as(u4, 0), evt.channel);

    switch (evt.message) {
        .control_change => |cc| {
            try std.testing.expectEqual(@as(u7, 7), cc.controller);
            try std.testing.expectEqual(@as(u7, 100), cc.value);
        },
        else => try std.testing.expect(false),
    }
}

test "parseMIDIPacket - control change with different channel" {
    var packet = MIDIPacket{
        .timeStamp = 0,
        .length = 3,
        .data = @as([256]u8, @splat(0)),
    };

    // Control Change: status 0xB3 (channel 3), controller 64 (sustain), value 127
    packet.data[0] = 0xB3;
    packet.data[1] = 64;
    packet.data[2] = 127;

    const event = CoreMIDIBackend.parseMIDIPacket(&packet);
    try std.testing.expect(event != null);

    const evt = event.?;
    try std.testing.expectEqual(@as(u4, 3), evt.channel);

    switch (evt.message) {
        .control_change => |cc| {
            try std.testing.expectEqual(@as(u7, 64), cc.controller);
            try std.testing.expectEqual(@as(u7, 127), cc.value);
        },
        else => try std.testing.expect(false),
    }
}

test "parseMIDIPacket - program change message" {
    var packet = MIDIPacket{
        .timeStamp = 0,
        .length = 2,
        .data = @as([256]u8, @splat(0)),
    };

    // Program Change: status 0xC0 (channel 0), program 42
    packet.data[0] = 0xC0;
    packet.data[1] = 42;

    const event = CoreMIDIBackend.parseMIDIPacket(&packet);
    try std.testing.expect(event != null);

    const evt = event.?;
    try std.testing.expectEqual(@as(u4, 0), evt.channel);

    switch (evt.message) {
        .program_change => |pc| {
            try std.testing.expectEqual(@as(u7, 42), pc.program);
        },
        else => try std.testing.expect(false),
    }
}

test "parseMIDIPacket - pitch bend message" {
    var packet = MIDIPacket{
        .timeStamp = 0,
        .length = 3,
        .data = @as([256]u8, @splat(0)),
    };

    // Pitch Bend: status 0xE0 (channel 0), LSB 0x00, MSB 0x40 (center = 8192)
    packet.data[0] = 0xE0;
    packet.data[1] = 0x00;
    packet.data[2] = 0x40;

    const event = CoreMIDIBackend.parseMIDIPacket(&packet);
    try std.testing.expect(event != null);

    const evt = event.?;
    try std.testing.expectEqual(@as(u4, 0), evt.channel);

    switch (evt.message) {
        .pitch_bend => |pb| {
            // Center position: (0x40 << 7) | 0x00 = 8192, minus 8192 = 0
            try std.testing.expectEqual(@as(i16, 0), pb.value);
        },
        else => try std.testing.expect(false),
    }
}

test "parseMIDIPacket - pitch bend max positive" {
    var packet = MIDIPacket{
        .timeStamp = 0,
        .length = 3,
        .data = @as([256]u8, @splat(0)),
    };

    // Pitch Bend: status 0xE0, LSB 0x7F, MSB 0x7F (max = 16383)
    packet.data[0] = 0xE0;
    packet.data[1] = 0x7F;
    packet.data[2] = 0x7F;

    const event = CoreMIDIBackend.parseMIDIPacket(&packet);
    try std.testing.expect(event != null);

    const evt = event.?;
    switch (evt.message) {
        .pitch_bend => |pb| {
            // Max value: (0x7F << 7) | 0x7F = 16383, minus 8192 = 8191
            try std.testing.expectEqual(@as(i16, 8191), pb.value);
        },
        else => try std.testing.expect(false),
    }
}

test "parseMIDIPacket - pitch bend max negative" {
    var packet = MIDIPacket{
        .timeStamp = 0,
        .length = 3,
        .data = @as([256]u8, @splat(0)),
    };

    // Pitch Bend: status 0xE0, LSB 0x00, MSB 0x00 (min = 0)
    packet.data[0] = 0xE0;
    packet.data[1] = 0x00;
    packet.data[2] = 0x00;

    const event = CoreMIDIBackend.parseMIDIPacket(&packet);
    try std.testing.expect(event != null);

    const evt = event.?;
    switch (evt.message) {
        .pitch_bend => |pb| {
            // Min value: (0x00 << 7) | 0x00 = 0, minus 8192 = -8192
            try std.testing.expectEqual(@as(i16, -8192), pb.value);
        },
        else => try std.testing.expect(false),
    }
}

test "parseMIDIPacket - channel extraction" {
    var packet = MIDIPacket{
        .timeStamp = 0,
        .length = 3,
        .data = @as([256]u8, @splat(0)),
    };

    // Test each MIDI channel (0-15)
    for (0..16) |ch| {
        const channel: u4 = @truncate(ch);
        packet.data[0] = 0x90 | @as(u8, channel);
        packet.data[1] = 60;
        packet.data[2] = 100;

        const event = CoreMIDIBackend.parseMIDIPacket(&packet);
        try std.testing.expect(event != null);
        try std.testing.expectEqual(channel, event.?.channel);
    }
}

test "parseMIDIPacket - data masking (7-bit values)" {
    var packet = MIDIPacket{
        .timeStamp = 0,
        .length = 3,
        .data = @as([256]u8, @splat(0)),
    };

    // Test that values are properly masked to 7 bits
    packet.data[0] = 0x90;
    packet.data[1] = 0xFF; // Should be masked to 0x7F (127)
    packet.data[2] = 0xFF; // Should be masked to 0x7F (127)

    const event = CoreMIDIBackend.parseMIDIPacket(&packet);
    try std.testing.expect(event != null);

    const evt = event.?;
    switch (evt.message) {
        .note_on => |note_on| {
            try std.testing.expectEqual(@as(u7, 127), note_on.note);
            try std.testing.expectEqual(@as(u7, 127), note_on.velocity);
        },
        else => try std.testing.expect(false),
    }
}

test "parseMIDIPacket - empty packet returns null" {
    var packet = MIDIPacket{
        .timeStamp = 0,
        .length = 0,
        .data = @as([256]u8, @splat(0)),
    };

    const event = CoreMIDIBackend.parseMIDIPacket(&packet);
    try std.testing.expect(event == null);
}

test "parseMIDIPacket - incomplete note on returns null" {
    var packet = MIDIPacket{
        .timeStamp = 0,
        .length = 2, // Only 2 bytes, need 3 for note on
        .data = @as([256]u8, @splat(0)),
    };

    packet.data[0] = 0x90;
    packet.data[1] = 60;

    const event = CoreMIDIBackend.parseMIDIPacket(&packet);
    try std.testing.expect(event == null);
}

test "parseMIDIPacket - incomplete control change returns null" {
    var packet = MIDIPacket{
        .timeStamp = 0,
        .length = 1, // Only 1 byte, need 3 for control change
        .data = @as([256]u8, @splat(0)),
    };

    packet.data[0] = 0xB0;

    const event = CoreMIDIBackend.parseMIDIPacket(&packet);
    try std.testing.expect(event == null);
}

test "parseMIDIPacket - unknown message type returns null" {
    var packet = MIDIPacket{
        .timeStamp = 0,
        .length = 3,
        .data = @as([256]u8, @splat(0)),
    };

    // System exclusive or other unsupported message
    packet.data[0] = 0xF0;
    packet.data[1] = 0x00;
    packet.data[2] = 0x00;

    const event = CoreMIDIBackend.parseMIDIPacket(&packet);
    try std.testing.expect(event == null);
}

test "CoreMIDIBackend - ring buffer queue and poll operations" {
    const allocator = std.testing.allocator;

    var backend = CoreMIDIBackend{
        .allocator = allocator,
    };

    // Create test events
    const event1 = MIDIEvent{
        .timestamp = 1000,
        .channel = 0,
        .message = .{ .note_on = .{ .note = 60, .velocity = 100 } },
    };

    const event2 = MIDIEvent{
        .timestamp = 2000,
        .channel = 1,
        .message = .{ .note_off = .{ .note = 72, .velocity = 64 } },
    };

    const event3 = MIDIEvent{
        .timestamp = 3000,
        .channel = 2,
        .message = .{ .control_change = .{ .controller = 7, .value = 127 } },
    };

    // Queue events
    backend.queueEvent(event1);
    backend.queueEvent(event2);
    backend.queueEvent(event3);

    // Poll events
    var buffer: [10]MIDIEvent = undefined;
    const count = backend.pollEvents(&buffer);

    try std.testing.expectEqual(@as(usize, 3), count);

    // Check first event
    try std.testing.expectEqual(@as(u64, 1000), buffer[0].timestamp);
    try std.testing.expectEqual(@as(u4, 0), buffer[0].channel);

    // Check second event
    try std.testing.expectEqual(@as(u64, 2000), buffer[1].timestamp);
    try std.testing.expectEqual(@as(u4, 1), buffer[1].channel);

    // Check third event
    try std.testing.expectEqual(@as(u64, 3000), buffer[2].timestamp);
    try std.testing.expectEqual(@as(u4, 2), buffer[2].channel);

    // Queue should be empty now
    const count2 = backend.pollEvents(&buffer);
    try std.testing.expectEqual(@as(usize, 0), count2);
}

test "CoreMIDIBackend - ring buffer wrapping" {
    const allocator = std.testing.allocator;

    var backend = CoreMIDIBackend{
        .allocator = allocator,
    };

    // Fill the queue with more than the buffer can hold to test wrapping
    const test_event = MIDIEvent{
        .timestamp = 1000,
        .channel = 0,
        .message = .{ .note_on = .{ .note = 60, .velocity = 100 } },
    };

    // Queue 50 events
    for (0..50) |_| {
        backend.queueEvent(test_event);
    }

    // Poll 30 events (leaving 20 in queue)
    var buffer: [30]MIDIEvent = undefined;
    const count1 = backend.pollEvents(&buffer);
    try std.testing.expectEqual(@as(usize, 30), count1);

    // Queue 20 more events (total should be 40 now: 20 remaining + 20 new)
    for (0..20) |_| {
        backend.queueEvent(test_event);
    }

    // Poll remaining events (should get all 40)
    const count2 = backend.pollEvents(&buffer);
    try std.testing.expectEqual(@as(usize, 30), count2);

    // Get the final 10
    const count3 = backend.pollEvents(&buffer);
    try std.testing.expectEqual(@as(usize, 10), count3);
}

test "CoreMIDIBackend - poll with smaller buffer" {
    const allocator = std.testing.allocator;

    var backend = CoreMIDIBackend{
        .allocator = allocator,
    };

    const event = MIDIEvent{
        .timestamp = 1000,
        .channel = 0,
        .message = .{ .note_on = .{ .note = 60, .velocity = 100 } },
    };

    // Queue 10 events
    for (0..10) |_| {
        backend.queueEvent(event);
    }

    // Poll with buffer of size 5
    var buffer: [5]MIDIEvent = undefined;
    const count1 = backend.pollEvents(&buffer);
    try std.testing.expectEqual(@as(usize, 5), count1);

    // Poll remaining 5 events
    const count2 = backend.pollEvents(&buffer);
    try std.testing.expectEqual(@as(usize, 5), count2);

    // Queue should be empty
    const count3 = backend.pollEvents(&buffer);
    try std.testing.expectEqual(@as(usize, 0), count3);
}

test "CoreMIDIBackend - event callback setup" {
    const allocator = std.testing.allocator;

    var backend = CoreMIDIBackend{
        .allocator = allocator,
    };

    // Create a dummy callback
    const dummy_callback = struct {
        fn callback(_: MIDIEvent, _: ?*anyopaque) void {}
    }.callback;

    var user_data: i32 = 42;

    // Set callback
    backend.setEventCallback(dummy_callback, &user_data);

    try std.testing.expect(backend.event_callback != null);
    try std.testing.expect(backend.callback_user_data != null);
}

test "detectCoreMIDI - platform detection" {
    if (builtin.os.tag == .macos) {
        try std.testing.expect(detectCoreMIDI());
    } else {
        try std.testing.expect(!detectCoreMIDI());
    }
}

test "CoreMIDIBackend - getSourceCount on non-macOS returns 0" {
    if (builtin.os.tag != .macos) {
        const count = CoreMIDIBackend.getSourceCount();
        try std.testing.expectEqual(@as(usize, 0), count);
    }
}

test "CoreMIDIBackend - getDestinationCount on non-macOS returns 0" {
    if (builtin.os.tag != .macos) {
        const count = CoreMIDIBackend.getDestinationCount();
        try std.testing.expectEqual(@as(usize, 0), count);
    }
}

/// Builds a MIDIPacketList byte-for-byte as CoreMIDI delivers it:
/// `#pragma pack(4)`, so the first packet starts at offset 4, each packet is
/// timeStamp (8) + length (2) + data, and on arm64 the next packet starts at
/// the following 4-byte boundary.
fn buildCoreMIDIPacketList(buf: []align(4) u8, packets: []const []const u8) []align(4) u8 {
    @memset(buf, 0);
    std.mem.writeInt(u32, buf[0..4], @intCast(packets.len), .little);
    var off: usize = 4;
    for (packets, 0..) |data, i| {
        std.mem.writeInt(u64, buf[off..][0..8], 1000 + i, .little);
        std.mem.writeInt(u16, buf[off + 8 ..][0..2], @intCast(data.len), .little);
        @memcpy(buf[off + 10 ..][0..data.len], data);
        off = packetListNextOffset(off, data.len);
    }
    return buf[0..off];
}

test "midiReadCallback - parses CoreMIDI's packed packet list layout" {
    var backend = CoreMIDIBackend{ .allocator = std.testing.allocator };

    var buf: [128]u8 align(4) = undefined;
    // A 3-byte note on, then a 3-byte CC: the second packet only lines up if
    // offsets follow Apple's packed layout rather than Zig's natural alignment.
    const list = buildCoreMIDIPacketList(&buf, &.{ &.{ 0x92, 60, 100 }, &.{ 0xB0, 7, 64 } });

    // The source connection refCon carries the backend; the port refCon is
    // unused because it was captured before the backend reached its final address.
    CoreMIDIBackend.midiReadCallback(list.ptr, null, &backend);

    var events: [4]MIDIEvent = undefined;
    const n = backend.pollEvents(&events);
    try std.testing.expectEqual(@as(usize, 2), n);
    try std.testing.expectEqual(@as(u64, 1000), events[0].timestamp);
    try std.testing.expectEqual(@as(u4, 2), events[0].channel);
    try std.testing.expectEqual(@as(u7, 60), events[0].message.note_on.note);
    try std.testing.expectEqual(@as(u7, 100), events[0].message.note_on.velocity);
    try std.testing.expectEqual(@as(u64, 1001), events[1].timestamp);
    try std.testing.expectEqual(@as(u7, 7), events[1].message.control_change.controller);
    try std.testing.expectEqual(@as(u7, 64), events[1].message.control_change.value);
}

test "midiReadCallback - ignores a list with no backend" {
    var buf: [64]u8 align(4) = undefined;
    const list = buildCoreMIDIPacketList(&buf, &.{&.{ 0x90, 60, 100 }});
    CoreMIDIBackend.midiReadCallback(list.ptr, null, null);
}
