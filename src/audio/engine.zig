const std = @import("std");
const backend_mod = @import("backend.zig");
const Backend = backend_mod.Backend;
const Track = @import("track.zig").Track;
const capture_source = @import("capture_source.zig");
const pdc = @import("pdc.zig");
const effects = @import("../effects/effects.zig");
const EffectsChain = effects.EffectsChain;
const rt_safe = @import("rt_safe.zig");
const midi_clip = @import("../midi/midi_clip.zig");
const detect = @import("../system/detect.zig");
const recording_mod = @import("recording.zig");
const mastering_mod = @import("mastering.zig");
const automation = @import("automation.zig");
const Lane = automation.Lane;
const Effect = effects.Effect;
const MAX_TRACK_GAIN = @import("../project/project.zig").MAX_TRACK_GAIN;
const note_ring = @import("../midi/note_ring.zig");
const event_queue = @import("event_queue.zig");
const LinearRamp = @import("../dsp/core.zig").LinearRamp;
const alsa_seq = @import("../midi/alsa_seq.zig");

/// Index of the Wet parameter of the reverb effect.
const REVERB_WET_PARAM = 3;

const log = std.log.scoped(.audio_engine);

/// Device names are stored NUL-terminated in this many bytes, so names are at most 127 bytes.
pub const DEVICE_NAME_CAPACITY = 128;

/// Why a settings change was refused. The C API maps these to its return codes.
pub const SettingError = error{
    /// Not in the detected list, or a name of 128 bytes or longer (-2).
    InvalidValue,
    /// The current backend cannot route to the requested device (-3).
    Unsupported,
    /// The backend could not be re-opened; the previous settings are still active (-4).
    ReopenFailed,
    /// A recording is in progress (-5).
    Busy,
};

/// Backend preferences accepted by `setBackend`. Must match `backend_names` in
/// src/config/audio_settings.zig, which is the list saved to audio.conf.
const backend_preferences = [_][]const u8{ "auto", "pulse", "pipewire", "none" };

/// The static storage name equal to `name` among `backend_preferences`, or null.
fn knownPreference(name: []const u8) ?[]const u8 {
    for (backend_preferences) |known| {
        if (std.mem.eql(u8, known, name)) return known;
    }
    return null;
}

/// Whether `list` contains `value`.
fn isListed(value: u32, list: []const u32) bool {
    for (list) |item| {
        if (item == value) return true;
    }
    return false;
}

/// Name stored in a NUL-terminated device buffer (empty means the system default).
fn deviceSlice(buf: *const [DEVICE_NAME_CAPACITY]u8) []const u8 {
    return std.mem.sliceTo(buf, 0);
}

fn storeDeviceName(buf: *[DEVICE_NAME_CAPACITY]u8, name: []const u8) void {
    @memset(buf, 0);
    @memcpy(buf[0..name.len], name);
}

fn checkDeviceName(name: []const u8) SettingError!void {
    if (name.len >= DEVICE_NAME_CAPACITY) return error.InvalidValue;
}

// Helper function to reduce atomic array initialization duplication
fn initAtomicArray(comptime T: type, comptime N: usize, init_val: T) [N]std.atomic.Value(T) {
    var arr: [N]std.atomic.Value(T) = undefined;
    for (&arr) |*item| {
        item.* = std.atomic.Value(T).init(init_val);
    }
    return arr;
}

/// How long a manual gain or pan change takes to reach its new value.
pub const PARAM_RAMP_MS = 10;

/// A manual mixer value as the audio thread applies it: the control thread sets a target, and
/// the audio thread moves toward it linearly, one step per sample, over `PARAM_RAMP_MS`. The
/// ramp length is in samples, so the result does not depend on the block size. Audio thread only.
const ParamRamp = struct {
    ramp: LinearRamp = .{},
    primed: bool = false,

    /// Aim at `target`. The first call jumps there: no audio has been made yet to smooth.
    fn aim(self: *ParamRamp, target: f32, ramp_frames: usize) void {
        if (!self.primed) return self.jump(target);
        if (target != self.ramp.target) self.ramp.rampTo(target, ramp_frames);
    }

    /// Value for the next sample.
    fn next(self: *ParamRamp) f32 {
        return self.ramp.process();
    }

    /// Continue from `value` with no ramp (after an automation curve, or while nothing is heard).
    fn jump(self: *ParamRamp, value: f32) void {
        self.ramp = LinearRamp.init(value);
        self.primed = true;
    }
};

pub const EngineConfig = struct {
    sample_rate: u32 = 48000,
    buffer_size: u32 = 128,
    backend_preference: []const u8 = "auto",
};

pub const AudioEngine = struct {
    // Constants
    pub const TRACK_COUNT = 8;
    /// Longest block the mixer handles (the stack buffers in mixBlock are sized for it).
    const MAX_BLOCK_FRAMES = 2048;
    /// Effect parameter automation is evaluated once per this many timeline frames (spec: at most 32).
    pub const AUTOMATION_GRID_FRAMES = 32;
    /// Most clip note ons and offs one track plays in one block; later ones are dropped.
    const MAX_CLIP_EVENTS = 256;

    allocator: std.mem.Allocator,
    config: EngineConfig,
    backend: Backend,

    // Selected devices; all zero means the system default
    output_device: [DEVICE_NAME_CAPACITY]u8 = @splat(0),
    input_device: [DEVICE_NAME_CAPACITY]u8 = @splat(0),

    // Transport state
    position: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    playing: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    recording: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    // Gain controls (0.0 to 1.0)
    track_gains: [TRACK_COUNT]std.atomic.Value(f32) = initAtomicArray(f32, TRACK_COUNT, 0.75),
    master_gain: std.atomic.Value(f32) = std.atomic.Value(f32).init(0.75),
    /// Per-sample ramps toward the manual gains and pans above (audio thread state).
    track_gain_ramps: [TRACK_COUNT]ParamRamp = @splat(.{}),
    track_pan_ramps: [TRACK_COUNT]ParamRamp = @splat(.{}),
    master_gain_ramp: ParamRamp = .{},

    // Automation lanes. Written from the UI thread, read in mixBlock. While playing (and in
    // offline renders) a lane with points overrides the manual value above; when stopped the
    // manual value is used again. A lane without points never overrides anything.
    track_gain_lanes: [TRACK_COUNT]Lane = @splat(.{}),
    track_pan_lanes: [TRACK_COUNT]Lane = @splat(.{}),
    track_wet_lanes: [TRACK_COUNT]Lane = @splat(.{}),
    master_gain_lane: Lane = .{},
    /// Reverb wet value found before automation took over, per track; restored when it stops.
    wet_manual: [TRACK_COUNT]?f32 = @splat(null),

    // Metering (0.0 to 1.0)
    track_meters: [TRACK_COUNT]std.atomic.Value(f32) = initAtomicArray(f32, TRACK_COUNT, 0.0),
    master_meter_left: std.atomic.Value(f32) = std.atomic.Value(f32).init(0.0),
    master_meter_right: std.atomic.Value(f32) = std.atomic.Value(f32).init(0.0),

    // Mute/Solo/Arm state
    track_muted: [TRACK_COUNT]std.atomic.Value(bool) = initAtomicArray(bool, TRACK_COUNT, false),
    track_solo: [TRACK_COUNT]std.atomic.Value(bool) = initAtomicArray(bool, TRACK_COUNT, false),
    track_armed: [TRACK_COUNT]std.atomic.Value(bool) = initAtomicArray(bool, TRACK_COUNT, false),

    // Audio tracks
    tracks: [TRACK_COUNT]Track = undefined,
    use_test_tones: bool = true,

    /// Live input provider for tracks with `input_enabled`. Set before audio runs (or while
    /// stopped); `capture_ready` publishes it to the audio thread.
    capture: capture_source.CaptureSource = undefined,
    capture_ready: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    // Test tone generation (fallback when no audio loaded)
    oscillator_phase: [TRACK_COUNT]f32 = @as([TRACK_COUNT]f32, @splat(0.0)),

    // Effects chains (per-track + master) - initialized in init()
    track_effects: [TRACK_COUNT]EffectsChain = undefined,
    master_effects: EffectsChain = undefined,

    /// Plugin delay compensation: one delay line per track, allocated in init.
    pdc_lines: [TRACK_COUNT]pdc.DelayLine = undefined,
    /// Whether a track skipped the last block, so its delay line holds stale audio.
    pdc_stale: [TRACK_COUNT]bool = @splat(true),
    /// Largest track effect latency in frames at the last mixed block (for export and UI).
    pdc_latency: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),

    // Mastering (glue compressor + -1 dBTP limiter + loudness meter) after master gain
    mastering: mastering_mod.Mastering = mastering_mod.Mastering.init(),

    // Statistics
    cpu_usage: std.atomic.Value(f32) = std.atomic.Value(f32).init(0.0),
    buffer_underruns: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),

    // Audio health monitoring (crash prevention analytics)
    nan_inf_count: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    clip_count: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    last_health_log_time: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),

    // Tempo and MIDI playback
    tempo: std.atomic.Value(f32) = std.atomic.Value(f32).init(120.0), // BPM

    /// Hardware MIDI input: the poll thread pushes, the audio thread drains.
    midi_ring: note_ring.NoteRing = .{},
    /// Note events from every other thread (UI audition, CLI socket, MIDI backend callbacks).
    /// Only the audio thread touches instrument voices; it drains this at the start of a block.
    control_events: event_queue.EventQueue = .{},
    /// Track whose instrument receives hardware MIDI notes (set by the UI).
    midi_input_track: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    /// ALSA sequencer input, created lazily by the C API (non-audio thread only).
    midi_input: ?*alsa_seq.AlsaSeq = null,
    last_beat_position: f64 = 0.0, // For tracking MIDI note events
    /// Clip note events of the block being rendered, per track (filled by collectClipEvents).
    clip_events: [TRACK_COUNT][MAX_CLIP_EVENTS]midi_clip.ClipEvent = undefined,
    clip_event_count: [TRACK_COUNT]usize = @splat(0),

    pub fn init(base_allocator: std.mem.Allocator, config: EngineConfig) !AudioEngine {
        log.info("Initializing audio engine (rate={d}, buffer={d})", .{ config.sample_rate, config.buffer_size });

        const allocator = rt_safe.init(base_allocator);

        // Initialize backend
        const backend_config = backend_mod.BackendConfig{
            .sample_rate = config.sample_rate,
            .buffer_size = config.buffer_size,
            .channels = 2,
            .device = "",
        };

        var backend = try Backend.init(allocator, backend_config, config.backend_preference);
        errdefer backend.deinit();

        // Initialize tracks
        var tracks: [TRACK_COUNT]Track = undefined;
        for (&tracks) |*track| {
            track.* = Track.init(allocator);
        }

        // Initialize effects chains with allocator
        var track_effects: [TRACK_COUNT]EffectsChain = undefined;
        for (&track_effects) |*chain| {
            chain.* = EffectsChain.init(allocator);
            chain.sample_rate = config.sample_rate;
        }
        var master_effects = EffectsChain.init(allocator);
        master_effects.sample_rate = config.sample_rate;

        var pdc_lines: [TRACK_COUNT]pdc.DelayLine = undefined;
        var pdc_built: usize = 0;
        errdefer for (pdc_lines[0..pdc_built]) |*line| line.deinit(allocator);
        for (&pdc_lines) |*line| {
            line.* = try pdc.DelayLine.init(allocator);
            pdc_built += 1;
        }

        return AudioEngine{
            .pdc_lines = pdc_lines,
            .allocator = allocator,
            .config = config,
            .backend = backend,
            .tracks = tracks,
            .track_effects = track_effects,
            .master_effects = master_effects,
        };
    }

    /// Connect this engine to the backend for audio callbacks.
    /// Must be called after the engine is stored at a stable address.
    pub fn connectBackend(self: *AudioEngine) void {
        self.backend.setEngine(self, processWrapper);
        log.info("Audio engine connected to backend", .{});
    }

    /// Wrapper function that matches the callback signature expected by backends
    fn processWrapper(engine_ptr: *anyopaque, output: []f32) void {
        const self: *AudioEngine = @ptrCast(@alignCast(engine_ptr));
        self.process(output);
    }

    pub fn deinit(self: *AudioEngine) void {
        log.info("Shutting down audio engine", .{});
        if (self.midi_input) |m| m.destroy();
        self.midi_input = null;
        self.backend.deinit();

        // Clean up tracks
        for (&self.tracks) |*track| {
            track.deinit();
        }

        // Clean up effects chains
        for (&self.track_effects) |*chain| {
            chain.deinit();
        }
        self.master_effects.deinit();
        for (&self.pdc_lines) |*line| line.deinit(self.allocator);
    }

    pub fn start(self: *AudioEngine) !void {
        log.info("Starting audio playback", .{});
        self.playing.store(true, .monotonic);
        try self.backend.start();
    }

    pub fn stop(self: *AudioEngine) void {
        log.info("Stopping audio playback", .{});
        self.playing.store(false, .monotonic);
        self.backend.stop();
    }

    /// Install the capture provider that input-enabled tracks read from.
    pub fn setCaptureSource(self: *AudioEngine, source: capture_source.CaptureSource) void {
        self.capture_ready.store(false, .release);
        self.capture = source;
        self.capture_ready.store(true, .release);
    }

    pub fn process(self: *AudioEngine, output: []f32) void {
        // REAL-TIME THREAD - NO ALLOCATIONS
        const frames = output.len / 2; // stereo

        self.drainControlEvents();
        self.drainMidiInput();

        if (self.playing.load(.monotonic)) {
            self.collectClipEvents(self.position.load(.monotonic), frames, .audio);
        } else {
            self.clip_event_count = @splat(0);
        }

        self.mixBlock(output, self.position.load(.monotonic), self.playing.load(.monotonic), .audio);

        // Update position when playing
        if (self.playing.load(.monotonic)) {
            // Advance by the frames actually delivered (the backend may use a different
            // block size than config.buffer_size). fetchAdd, not load+store, so a
            // concurrent set_position(0) from Stop is never overwritten by a stale value.
            _ = self.position.fetchAdd(frames, .monotonic);
        }
    }

    /// Route queued hardware MIDI notes to the selected track's instrument.
    /// Events for a track without an instrument are dropped. Audio thread: no locks or allocation.
    fn drainMidiInput(self: *AudioEngine) void {
        const track = self.midi_input_track.load(.monotonic);
        while (self.midi_ring.pop()) |ev| {
            if (track >= TRACK_COUNT) continue;
            if (self.tracks[track].getInstrument() == null) continue;
            if (ev.on) {
                self.tracks[track].noteOn(ev.note, ev.velocity);
            } else {
                self.tracks[track].noteOff(ev.note);
            }
        }
    }

    /// Apply queued note events from control threads. Audio thread: no locks or allocation.
    fn drainControlEvents(self: *AudioEngine) void {
        while (self.control_events.pop()) |ev| {
            const track = &self.tracks[ev.track];
            switch (ev.kind) {
                .note_on => track.noteOn(ev.note, ev.velocity),
                .note_off => track.noteOff(ev.note),
                .all_notes_off => if (track.getInstrument()) |inst| inst.allNotesOff(),
            }
        }
    }

    /// Queue an event for the audio thread. False when the track is out of range or the queue
    /// is full (the event is dropped; the queue counts it). Any thread.
    fn queueEvent(self: *AudioEngine, event: event_queue.Event) bool {
        if (event.track >= TRACK_COUNT or event.note > 127 or event.velocity > 127) return false;
        return self.control_events.push(event);
    }

    /// Ask the audio thread to start a note on `track`'s instrument at its next block.
    /// Any thread; never touches voice state itself. False when refused (see `queueEvent`).
    pub fn queueNoteOn(self: *AudioEngine, track: usize, note: u8, velocity: u8) bool {
        if (track >= TRACK_COUNT) return false;
        return self.queueEvent(.{ .track = @intCast(track), .kind = .note_on, .note = note, .velocity = velocity });
    }

    /// Ask the audio thread to release a note on `track`'s instrument. Any thread.
    pub fn queueNoteOff(self: *AudioEngine, track: usize, note: u8) bool {
        if (track >= TRACK_COUNT) return false;
        return self.queueEvent(.{ .track = @intCast(track), .kind = .note_off, .note = note });
    }

    /// Ask the audio thread to silence every voice of `track`'s instrument. Any thread.
    pub fn queueAllNotesOff(self: *AudioEngine, track: usize) bool {
        if (track >= TRACK_COUNT) return false;
        return self.queueEvent(.{ .track = @intCast(track), .kind = .all_notes_off });
    }

    /// Open the ALSA sequencer input on first use and start its poll thread.
    /// Call from a non-audio thread. Returns null if ALSA is unavailable.
    pub fn midiInput(self: *AudioEngine) ?*alsa_seq.AlsaSeq {
        if (self.midi_input) |m| return m;
        const m = alsa_seq.AlsaSeq.create(self.allocator, &self.midi_ring) catch |err| {
            log.warn("MIDI input unavailable: {}", .{err});
            return null;
        };
        m.startThread() catch |err| {
            log.warn("MIDI input thread failed: {}", .{err});
            m.destroy();
            return null;
        };
        self.midi_input = m;
        return m;
    }

    /// Select the track that hardware MIDI input plays. Out-of-range tracks are ignored.
    pub fn setMidiInputTrack(self: *AudioEngine, track: usize) void {
        if (track < TRACK_COUNT) self.midi_input_track.store(track, .monotonic);
    }

    /// Gather the clip note ons and offs of the block starting at `start_sample`, each on its own
    /// frame; mixBlock plays them sample-accurately. `reader` names the calling thread's
    /// snapshot slot (`.audio` or `.offline`). No locks, allocation or logging.
    fn collectClipEvents(self: *AudioEngine, start_sample: u64, frames: usize, reader: midi_clip.Reader) void {
        const tempo_bpm: f64 = self.tempo.load(.monotonic);
        const sample_rate_f: f64 = @floatFromInt(self.config.sample_rate);
        const samples_per_beat = sample_rate_f * 60.0 / tempo_bpm;
        for (0..TRACK_COUNT) |track_idx| {
            self.clip_event_count[track_idx] = midi_clip.collectBlockEvents(track_idx, reader, start_sample, frames, samples_per_beat, &self.clip_events[track_idx]);
        }
        self.last_beat_position = @as(f64, @floatFromInt(start_sample + frames)) / samples_per_beat;
    }

    /// Mix all tracks into `output` (stereo interleaved). Does not touch the transport.
    /// `start_sample` is the timeline position of the first frame; `automate` says whether
    /// automation lanes override the manual values for this block.
    fn mixBlock(self: *AudioEngine, output: []f32, start_sample: u64, automate: bool, reader: midi_clip.Reader) void {
        const frames = output.len / 2; // stereo
        const master_gain = self.master_gain.load(.monotonic);

        // Timeline position of this block in beats, and the beats one frame covers.
        const sample_rate_f: f64 = @floatFromInt(self.config.sample_rate);
        const beats_per_sample: f64 = self.tempo.load(.monotonic) / 60.0 / sample_rate_f;
        const start_beat: f64 = @as(f64, @floatFromInt(start_sample)) * beats_per_sample;

        // Per-frame curves; each is only used when its lane has points.
        var gain_curve_storage: [MAX_BLOCK_FRAMES]f32 = undefined;
        var pan_curve_storage: [MAX_BLOCK_FRAMES]f32 = undefined;
        var master_curve_storage: [MAX_BLOCK_FRAMES]f32 = undefined;
        const block = @min(frames, MAX_BLOCK_FRAMES);
        const gain_curve = gain_curve_storage[0..block];
        const pan_curve = pan_curve_storage[0..block];
        const master_curve = master_curve_storage[0..block];
        const master_automated = automate and block == frames and
            self.master_gain_lane.fill(start_beat, beats_per_sample, master_curve);
        const ramp_frames: usize = @max(1, self.config.sample_rate * PARAM_RAMP_MS / 1000);
        if (master_automated) {
            for (master_curve) |*v| v.* = std.math.clamp(v.*, 0.0, 1.0);
            self.master_gain_ramp.jump(master_curve[block - 1]);
        } else {
            self.master_gain_ramp.aim(master_gain, ramp_frames);
            for (master_curve) |*v| v.* = self.master_gain_ramp.next();
        }

        // Clear output buffer
        @memset(output, 0.0);

        // Check if any track is soloed
        var any_solo = false;
        for (&self.track_solo) |*solo| {
            if (solo.load(.monotonic)) {
                any_solo = true;
                break;
            }
        }

        // Track metering
        var track_peak_levels: [TRACK_COUNT]f32 = @as([TRACK_COUNT]f32, @splat(0.0));
        var master_peak_left: f32 = 0.0;
        var master_peak_right: f32 = 0.0;

        // Temporary buffer for per-track processing (on stack - no allocation)
        var track_buffer: [4096]f32 = undefined;
        const track_buf = track_buffer[0 .. frames * 2];
        var capture_buffer: [4096]f32 = undefined;
        const capture_buf = capture_buffer[0 .. frames * 2];
        const capture_ready = self.capture_ready.load(.acquire);

        // Reverb wet automation: every track once per block, so the manual value comes back on
        // stop; audible automated tracks then step it on a 32-sample grid (processTrackEffects).
        const mid_beat = start_beat + beats_per_sample * @as(f64, @floatFromInt(frames)) * 0.5;
        for (0..TRACK_COUNT) |track_idx| self.applyWetAutomation(track_idx, automate, mid_beat);

        // Plugin delay compensation: delay every track to match the slowest effects chain.
        var track_latency: [TRACK_COUNT]usize = undefined;
        var max_latency: usize = 0;
        for (&self.track_effects, 0..) |*chain, i| {
            track_latency[i] = chain.latencySamples();
            max_latency = @max(max_latency, track_latency[i]);
        }
        self.pdc_latency.store(@intCast(@min(max_latency, pdc.MAX_DELAY_FRAMES - 1)), .monotonic);

        // Process each track
        for (0..TRACK_COUNT) |track_idx| {
            const is_armed = self.track_armed[track_idx].load(.monotonic);
            const has_instrument = self.tracks[track_idx].getInstrument() != null;
            const has_midi = midi_clip.hasPlaybackNotes(track_idx, reader);
            const has_audio_clip = self.tracks[track_idx].clip != null;
            const has_input = capture_ready and self.tracks[track_idx].input_enabled and self.tracks[track_idx].input_device >= 0;

            // Skip tracks without content (no audio clip, no instrument, not armed, no input)
            if (!self.tracks[track_idx].is_active and !is_armed and !has_instrument and !has_midi and !has_audio_clip and !has_input) {
                self.pdc_stale[track_idx] = true;
                self.applyClipEventsSilently(track_idx);
                self.settleRamps(track_idx);
                continue;
            }

            const muted = self.track_muted[track_idx].load(.monotonic);
            const soloed = self.track_solo[track_idx].load(.monotonic);
            const track_gain = self.track_gains[track_idx].load(.monotonic);

            // Check if track should be audible
            const audible = if (any_solo) soloed else !muted;

            if (audible) {
                // Clear track buffer
                @memset(track_buf, 0.0);

                const gain_automated = automate and block == frames and
                    self.track_gain_lanes[track_idx].fill(start_beat, beats_per_sample, gain_curve);
                const pan_automated = automate and block == frames and
                    self.track_pan_lanes[track_idx].fill(start_beat, beats_per_sample, pan_curve);
                if (pan_automated) {
                    for (pan_curve) |*v| v.* = std.math.clamp(v.*, -1.0, 1.0);
                    self.track_pan_ramps[track_idx].jump(pan_curve[block - 1]);
                } else {
                    const pan_ramp = &self.track_pan_ramps[track_idx];
                    pan_ramp.aim(self.tracks[track_idx].getPan(), ramp_frames);
                    for (pan_curve) |*v| v.* = pan_ramp.next();
                }
                if (gain_automated) {
                    for (gain_curve) |*v| v.* = std.math.clamp(v.*, 0.0, 1.0);
                    self.track_gain_ramps[track_idx].jump(gain_curve[block - 1]);
                } else {
                    const gain_ramp = &self.track_gain_ramps[track_idx];
                    gain_ramp.aim(track_gain, ramp_frames);
                    for (gain_curve) |*v| v.* = gain_ramp.next();
                }

                // Get audio from track's instrument (if any)
                const events = self.clip_events[track_idx][0..self.clip_event_count[track_idx]];
                self.tracks[track_idx].processPanned(track_buf, self.config.sample_rate, pan_curve, events);

                // Live input: mix the captured block in before gain and effects
                if (has_input) {
                    @memset(capture_buf, 0.0);
                    const written = @min(self.capture.read(self.capture.context, self.tracks[track_idx].input_device, capture_buf), capture_buf.len);
                    for (0..written) |i| track_buf[i] += capture_buf[i];
                }

                // Apply track gain (automation curve or the ramp toward the fader), per sample
                for (0..frames) |frame| {
                    track_buf[frame * 2] *= gain_curve[frame];
                    track_buf[frame * 2 + 1] *= gain_curve[frame];
                }

                // Apply track effects chain
                self.processTrackEffects(track_idx, track_buf, start_sample, beats_per_sample, automate);

                // Line this track up with the slowest chain.
                if (self.pdc_stale[track_idx]) {
                    self.pdc_lines[track_idx].clear();
                    self.pdc_stale[track_idx] = false;
                }
                self.pdc_lines[track_idx].process(track_buf, pdc.compensation(track_latency[track_idx], max_latency));

                // Measure peak after effects and mix to main output
                var track_peak: f32 = 0.0;
                for (0..frames) |frame| {
                    const abs_l = @abs(track_buf[frame * 2]);
                    const abs_r = @abs(track_buf[frame * 2 + 1]);
                    const peak = @max(abs_l, abs_r);
                    if (peak > track_peak) track_peak = peak;

                    // Mix to main output
                    output[frame * 2] += track_buf[frame * 2];
                    output[frame * 2 + 1] += track_buf[frame * 2 + 1];
                }

                track_peak_levels[track_idx] = track_peak;
            } else {
                self.pdc_stale[track_idx] = true;
                self.applyClipEventsSilently(track_idx);
                self.settleRamps(track_idx);
            }
        }

        // Apply master effects chain
        self.master_effects.process(output, self.config.sample_rate);

        // Apply master gain and sanitize (NaN/Inf must not reach the mastering state)
        var buffer_nan_count: u32 = 0;
        var buffer_clip_count: u32 = 0;

        for (0..frames) |frame| {
            const gain = master_curve[frame];
            var left = output[frame * 2] * gain;
            var right = output[frame * 2 + 1] * gain;

            // CRITICAL: Sanitize output to prevent NaN/Inf from corrupting CoreAudio
            // Track occurrences for crash analytics
            if (std.math.isNan(left) or std.math.isInf(left)) {
                left = 0.0;
                buffer_nan_count += 1;
            }
            if (std.math.isNan(right) or std.math.isInf(right)) {
                right = 0.0;
                buffer_nan_count += 1;
            }
            output[frame * 2] = left;
            output[frame * 2 + 1] = right;
        }

        // Mastering: glue compressor, then true-peak limiter (when enabled); always metered
        self.mastering.process(output[0 .. frames * 2], self.config.sample_rate);

        for (0..frames) |frame| {
            var left = output[frame * 2];
            var right = output[frame * 2 + 1];

            // Hard clip to prevent extreme values - track clipping
            const left_before = left;
            const right_before = right;
            left = std.math.clamp(left, -1.0, 1.0);
            right = std.math.clamp(right, -1.0, 1.0);
            if (left != left_before or right != right_before) {
                buffer_clip_count += 1;
            }

            output[frame * 2] = left;
            output[frame * 2 + 1] = right;

            const left_abs = @abs(left);
            const right_abs = @abs(right);

            if (left_abs > master_peak_left) {
                master_peak_left = left_abs;
            }
            if (right_abs > master_peak_right) {
                master_peak_right = right_abs;
            }
        }

        // Update health counters (atomic, no allocation)
        if (buffer_nan_count > 0) {
            _ = self.nan_inf_count.fetchAdd(buffer_nan_count, .monotonic);
        }
        if (buffer_clip_count > 0) {
            _ = self.clip_count.fetchAdd(buffer_clip_count, .monotonic);
        }

        // Update meters (atomic)
        for (0..TRACK_COUNT) |i| {
            self.track_meters[i].store(track_peak_levels[i], .monotonic);
        }
        self.master_meter_left.store(master_peak_left, .monotonic);
        self.master_meter_right.store(master_peak_right, .monotonic);
    }

    /// Runs a track's effects chain. While the track's reverb wet lane is automated, the chain
    /// runs in pieces cut on a timeline grid of `AUTOMATION_GRID_FRAMES`, with the wet amount set
    /// from the lane at the start of each grid cell, so effect automation does not depend on the
    /// block size.
    fn processTrackEffects(self: *AudioEngine, track_idx: usize, track_buf: []f32, start_sample: u64, beats_per_sample: f64, automate: bool) void {
        const chain = &self.track_effects[track_idx];
        const rate = self.config.sample_rate;
        if (!automate or !self.track_wet_lanes[track_idx].hasPoints() or self.trackReverb(track_idx) == null) {
            chain.process(track_buf, rate);
            return;
        }
        const frames = track_buf.len / 2;
        var done: usize = 0;
        while (done < frames) {
            const pos = start_sample + done;
            const cell_start = pos - pos % AUTOMATION_GRID_FRAMES;
            const n: usize = @intCast(@min(@as(u64, frames - done), cell_start + AUTOMATION_GRID_FRAMES - pos));
            self.applyWetAutomation(track_idx, true, @as(f64, @floatFromInt(cell_start)) * beats_per_sample);
            chain.process(track_buf[done * 2 .. (done + n) * 2], rate);
            done += n;
        }
    }

    /// A track that is not heard this block has nothing to smooth: its ramps jump to the
    /// manual values, so it comes back without a slide from a stale value.
    fn settleRamps(self: *AudioEngine, track_idx: usize) void {
        self.track_gain_ramps[track_idx].jump(self.track_gains[track_idx].load(.monotonic));
        self.track_pan_ramps[track_idx].jump(self.tracks[track_idx].getPan());
    }

    /// A track that is not rendered this block (silent or muted) still takes its clip note ons
    /// and offs, so no note hangs when it becomes audible again.
    fn applyClipEventsSilently(self: *AudioEngine, track_idx: usize) void {
        for (self.clip_events[track_idx][0..self.clip_event_count[track_idx]]) |event| {
            if (event.on) {
                self.tracks[track_idx].noteOn(event.pitch, event.velocity);
            } else {
                self.tracks[track_idx].noteOff(event.pitch);
            }
        }
    }

    /// The first reverb in a track's effects chain, if it has one.
    fn trackReverb(self: *AudioEngine, track: usize) ?*Effect {
        const chain = &self.track_effects[track];
        for (0..chain.count) |i| {
            if (chain.slots[i].effect_type == .reverb) return chain.getEffect(i);
        }
        return null;
    }

    /// Sets the track reverb's wet amount from its lane for the block centred on `beat`. When the
    /// lane has no points (or the engine is not automating) the wet value found before automation
    /// began is put back. Tracks without a reverb are skipped.
    fn applyWetAutomation(self: *AudioEngine, track: usize, automate: bool, beat: f64) void {
        const lane_value = if (automate) self.track_wet_lanes[track].valueAt(beat) else null;
        if (lane_value == null and self.wet_manual[track] == null) return;
        const reverb = self.trackReverb(track) orelse return;
        if (lane_value) |value| {
            if (self.wet_manual[track] == null) {
                if (reverb.getParameter(REVERB_WET_PARAM)) |param| self.wet_manual[track] = param.value;
            }
            reverb.setParameter(REVERB_WET_PARAM, std.math.clamp(value, 0.0, 1.0));
        } else if (self.wet_manual[track]) |manual| {
            reverb.setParameter(REVERB_WET_PARAM, manual);
            self.wet_manual[track] = null;
        }
    }

    /// Saved transport/track state for an offline render.
    pub const OfflineState = struct {
        clip_positions: [TRACK_COUNT]?u64,
        track_active: [TRACK_COUNT]bool,
        last_beat_position: f64,
    };

    /// Prepare for an offline render: remember cursors and track state, then rewind
    /// every clip cursor and silence instruments. The real transport is not moved.
    pub fn beginOfflineRender(self: *AudioEngine) OfflineState {
        var state: OfflineState = .{
            .clip_positions = @splat(null),
            .track_active = @splat(false),
            .last_beat_position = self.last_beat_position,
        };
        self.mastering.reset();
        // Delay lines hold live audio; the render must not start with it.
        self.pdc_stale = @splat(true);
        for (&self.tracks, 0..) |*track, i| {
            if (track.clip) |clip| state.clip_positions[i] = clip.position;
            state.track_active[i] = track.is_active;
            track.reset();
            if (track.getInstrument()) |inst| inst.allNotesOff();
            track.is_active = false;
        }
        return state;
    }

    /// Render one block offline, starting at `start_sample` on the timeline, using the
    /// same MIDI triggering and mixing as live playback but without moving the transport.
    pub fn renderOffline(self: *AudioEngine, output: []f32, start_sample: u64) void {
        self.collectClipEvents(start_sample, output.len / 2, .offline);
        self.mixBlock(output, start_sample, true, .offline);
    }

    /// Undo `beginOfflineRender`: silence export notes and restore cursors and track state.
    pub fn endOfflineRender(self: *AudioEngine, state: OfflineState) void {
        for (&self.tracks, 0..) |*track, i| {
            if (track.getInstrument()) |inst| inst.allNotesOff();
            if (track.clip) |*clip| {
                if (state.clip_positions[i]) |pos| clip.position = pos;
            }
            track.is_active = state.track_active[i];
        }
        self.last_beat_position = state.last_beat_position;
    }

    pub fn getCpuUsage(self: *const AudioEngine) f32 {
        return self.cpu_usage.load(.monotonic);
    }

    pub fn getPosition(self: *const AudioEngine) u64 {
        return self.position.load(.monotonic);
    }

    pub fn isPlaying(self: *const AudioEngine) bool {
        return self.playing.load(.monotonic);
    }

    pub fn isRecording(self: *const AudioEngine) bool {
        return self.recording.load(.monotonic);
    }

    // ---- Audio settings (UI thread only) -----------------------------------
    // Each setter validates, refuses while recording, then either stores the value
    // (input) or rebuilds the backend with the new value (output, rate, buffer).

    pub fn backendName(self: *const AudioEngine) []const u8 {
        return @tagName(std.meta.activeTag(self.backend));
    }

    /// The preference the engine was asked for ("auto", "pulse", "pipewire" or "none").
    pub fn backendPreference(self: *const AudioEngine) []const u8 {
        return self.config.backend_preference;
    }

    /// Restarts the engine on the named backend preference. The output device resets to the
    /// system default because device names belong to one backend; the caller re-applies a
    /// chosen device afterwards. On failure the previous backend keeps running.
    pub fn setBackend(self: *AudioEngine, name: []const u8) SettingError!void {
        const preference = knownPreference(name) orelse return error.InvalidValue;
        try self.ensureIdle();
        if (std.mem.eql(u8, preference, self.config.backend_preference)) return;
        try self.reopenBackend(self.config.sample_rate, self.config.buffer_size, "", preference);
        storeDeviceName(&self.output_device, "");
        self.config.backend_preference = preference;
    }

    pub fn outputDeviceName(self: *const AudioEngine) []const u8 {
        return deviceSlice(&self.output_device);
    }

    pub fn inputDeviceName(self: *const AudioEngine) []const u8 {
        return deviceSlice(&self.input_device);
    }

    pub fn setOutputDevice(self: *AudioEngine, name: []const u8) SettingError!void {
        try checkDeviceName(name);
        try self.ensureIdle();
        if (!backend_mod.canRouteTo(std.meta.activeTag(self.backend), name)) return error.Unsupported;
        if (std.mem.eql(u8, name, self.outputDeviceName())) return;
        try self.reopenBackend(self.config.sample_rate, self.config.buffer_size, name, self.backendName());
        storeDeviceName(&self.output_device, name);
    }

    /// Stored for the next capture; does not touch the playback backend or the transport.
    pub fn setInputDevice(self: *AudioEngine, name: []const u8) SettingError!void {
        try checkDeviceName(name);
        try self.ensureIdle();
        if (std.mem.eql(u8, name, self.inputDeviceName())) return;
        storeDeviceName(&self.input_device, name);
        recording_mod.setInputDevice(name);
    }

    pub fn setBufferSize(self: *AudioEngine, frames: u32) SettingError!void {
        if (!isListed(frames, detect.detect().buffer_sizes)) return error.InvalidValue;
        try self.ensureIdle();
        if (frames == self.config.buffer_size) return;
        try self.reopenBackend(self.config.sample_rate, frames, self.outputDeviceName(), self.backendName());
        self.config.buffer_size = frames;
    }

    /// Changes the rate and moves the transport so the song keeps its musical position.
    pub fn setSampleRate(self: *AudioEngine, rate: u32) SettingError!void {
        if (!isListed(rate, detect.detect().sample_rates)) return error.InvalidValue;
        try self.ensureIdle();
        if (rate == self.config.sample_rate) return;
        const old_rate = self.config.sample_rate;
        try self.reopenBackend(rate, self.config.buffer_size, self.outputDeviceName(), self.backendName());
        self.config.sample_rate = rate;
        const old_position: u128 = self.position.load(.monotonic);
        // Ratio of two u32 rates times a u64 position fits in u64 for any realistic session length.
        const new_position: u128 = old_position * @as(u128, rate) / @as(u128, old_rate);
        self.position.store(@intCast(new_position), .monotonic);
    }

    fn ensureIdle(self: *const AudioEngine) SettingError!void {
        if (self.recording.load(.monotonic) or recording_mod.isBusy()) return error.Busy;
    }

    /// Stop, build a backend for `preference` with new parameters, swap it in, and restart
    /// if it was playing. On failure the old backend is restarted and the old settings stay.
    fn reopenBackend(self: *AudioEngine, sample_rate: u32, buffer_size: u32, device: []const u8, preference: []const u8) SettingError!void {
        const was_playing = self.playing.load(.monotonic);
        self.stop();

        const config = backend_mod.BackendConfig{
            .sample_rate = sample_rate,
            .buffer_size = buffer_size,
            .channels = 2,
            .device = device,
        };
        const replacement = Backend.init(self.allocator, config, preference) catch |err| {
            log.err("Could not re-open audio backend: {}", .{err});
            if (was_playing) self.start() catch |restart_err| log.err("Could not restart audio: {}", .{restart_err});
            return error.ReopenFailed;
        };

        self.backend.deinit();
        self.backend = replacement;
        // No audio callback runs between the old backend's deinit and connectBackend,
        // so rate-bound effects can be rebuilt here without racing the audio thread.
        if (sample_rate != self.config.sample_rate) {
            for (&self.track_effects) |*chain| chain.setSampleRate(sample_rate);
            self.master_effects.setSampleRate(sample_rate);
        }
        self.connectBackend();
        if (was_playing) {
            self.start() catch |err| log.err("Settings applied but playback did not restart: {}", .{err});
        }
    }

    // Audio health monitoring (crash prevention analytics)
    pub fn getAudioHealthStats(self: *const AudioEngine) struct { nan_inf_count: u64, clip_count: u64 } {
        return .{
            .nan_inf_count = self.nan_inf_count.load(.monotonic),
            .clip_count = self.clip_count.load(.monotonic),
        };
    }

    pub fn resetAudioHealthStats(self: *AudioEngine) void {
        self.nan_inf_count.store(0, .monotonic);
        self.clip_count.store(0, .monotonic);
    }

    /// Log audio health stats if there have been issues (called from non-RT thread)
    pub fn logHealthStatsIfNeeded(self: *AudioEngine) void {
        const stats = self.getAudioHealthStats();
        if (stats.nan_inf_count > 0) {
            log.warn("Audio health: {d} NaN/Inf values sanitized (would have crashed CoreAudio)", .{stats.nan_inf_count});
        }
        if (stats.clip_count > 100) { // Only warn if significant clipping
            log.info("Audio health: {d} samples clipped", .{stats.clip_count});
        }
    }

    // Gain controls
    pub fn setTrackGain(self: *AudioEngine, track: usize, gain: f32) void {
        if (track >= TRACK_COUNT) return;
        const clamped = std.math.clamp(gain, 0.0, MAX_TRACK_GAIN);
        self.track_gains[track].store(clamped, .monotonic);
    }

    pub fn getTrackGain(self: *const AudioEngine, track: usize) f32 {
        if (track >= TRACK_COUNT) return 0.0;
        return self.track_gains[track].load(.monotonic);
    }

    pub fn setMasterGain(self: *AudioEngine, gain: f32) void {
        const clamped = @max(0.0, @min(1.0, gain));
        self.master_gain.store(clamped, .monotonic);
    }

    pub fn getMasterGain(self: *const AudioEngine) f32 {
        return self.master_gain.load(.monotonic);
    }

    /// Turn master-bus mastering (glue compressor + -1 dBTP limiter) on or off. Default on.
    pub fn setMasteringEnabled(self: *AudioEngine, enabled: bool) void {
        self.mastering.setEnabled(enabled);
    }

    /// Delay in frames that mastering adds to the output (0 when off).
    pub fn masteringLatencyFrames(self: *const AudioEngine) usize {
        return self.mastering.latencyFrames();
    }

    /// Delay the effects add to the master output, in frames: the slowest track chain
    /// (every track is compensated to it) plus the master chain. Control thread.
    pub fn effectsLatencyFrames(self: *const AudioEngine) usize {
        var max_track: usize = 0;
        for (&self.track_effects) |*chain| max_track = @max(max_track, chain.latencySamples());
        return @min(max_track, pdc.MAX_DELAY_FRAMES - 1) + self.master_effects.latencySamples();
    }

    pub fn isMasteringEnabled(self: *const AudioEngine) bool {
        return self.mastering.isEnabled();
    }

    /// Short-term (3 s) K-weighted loudness of the output in LUFS-like units; -70 is silence.
    pub fn getLoudness(self: *const AudioEngine) f32 {
        return self.mastering.getLoudness();
    }

    pub fn setTrackPan(self: *AudioEngine, track: usize, pan: f32) void {
        if (track >= TRACK_COUNT) return;
        const clamped = @max(-1.0, @min(1.0, pan));
        self.tracks[track].setPan(clamped);
    }

    pub fn getTrackPan(self: *const AudioEngine, track: usize) f32 {
        if (track >= TRACK_COUNT) return 0.0;
        return self.tracks[track].getPan();
    }

    // Automation (UI thread only)
    pub const AutomationTarget = enum { track_gain, track_pan, track_wet, master_gain };

    pub const AutomationError = error{ InvalidTrack, InvalidValue, LaneFull };

    fn automationLane(self: *AudioEngine, target: AutomationTarget, track: usize) AutomationError!*Lane {
        if (target == .master_gain) return &self.master_gain_lane;
        if (track >= TRACK_COUNT) return AutomationError.InvalidTrack;
        return switch (target) {
            .track_gain => &self.track_gain_lanes[track],
            .track_pan => &self.track_pan_lanes[track],
            .track_wet => &self.track_wet_lanes[track],
            .master_gain => unreachable,
        };
    }

    /// Adds a point (beat, value) to a lane. The value is clamped to the range of the target.
    /// `track` is ignored for the master gain.
    pub fn addAutomationPoint(self: *AudioEngine, target: AutomationTarget, track: usize, beat: f64, value: f32) AutomationError!void {
        if (!std.math.isFinite(beat) or beat < 0.0 or !std.math.isFinite(value)) return AutomationError.InvalidValue;
        const lane = try self.automationLane(target, track);
        const low: f32 = if (target == .track_pan) -1.0 else 0.0;
        lane.addPoint(beat, std.math.clamp(value, low, 1.0)) catch return AutomationError.LaneFull;
    }

    /// Removes every point of a lane; the manual value is used again.
    pub fn clearAutomation(self: *AudioEngine, target: AutomationTarget, track: usize) AutomationError!void {
        const lane = try self.automationLane(target, track);
        lane.clear();
    }

    /// Whether the track has a reverb whose wet amount a lane can drive.
    pub fn trackHasReverb(self: *AudioEngine, track: usize) bool {
        if (track >= TRACK_COUNT) return false;
        return self.trackReverb(track) != null;
    }

    // Mute/Solo controls
    pub fn setTrackMute(self: *AudioEngine, track: usize, muted: bool) void {
        if (track >= TRACK_COUNT) return;
        self.track_muted[track].store(muted, .monotonic);
    }

    pub fn getTrackMute(self: *const AudioEngine, track: usize) bool {
        if (track >= TRACK_COUNT) return false;
        return self.track_muted[track].load(.monotonic);
    }

    pub fn setTrackSolo(self: *AudioEngine, track: usize, soloed: bool) void {
        if (track >= TRACK_COUNT) return;
        self.track_solo[track].store(soloed, .monotonic);
    }

    pub fn getTrackSolo(self: *const AudioEngine, track: usize) bool {
        if (track >= TRACK_COUNT) return false;
        return self.track_solo[track].load(.monotonic);
    }

    // Record arm controls
    pub fn setTrackArm(self: *AudioEngine, track: usize, armed: bool) void {
        if (track >= TRACK_COUNT) return;
        self.track_armed[track].store(armed, .monotonic);
    }

    pub fn getTrackArm(self: *const AudioEngine, track: usize) bool {
        if (track >= TRACK_COUNT) return false;
        return self.track_armed[track].load(.monotonic);
    }

    // Metering
    pub fn getTrackMeter(self: *const AudioEngine, track: usize) f32 {
        if (track >= TRACK_COUNT) return 0.0;
        return self.track_meters[track].load(.monotonic);
    }

    pub fn getMasterMeterLeft(self: *const AudioEngine) f32 {
        return self.master_meter_left.load(.monotonic);
    }

    pub fn getMasterMeterRight(self: *const AudioEngine) f32 {
        return self.master_meter_right.load(.monotonic);
    }

    // Track management
    pub fn loadTrackFile(self: *AudioEngine, track_index: usize, path: []const u8) !void {
        if (track_index >= TRACK_COUNT) return error.InvalidTrackIndex;

        try self.tracks[track_index].loadFile(path);
        log.info("Loaded file into track {}: {s}", .{ track_index, path });

        // Switch to real audio mode
        self.use_test_tones = false;
    }

    pub fn resetTracks(self: *AudioEngine) void {
        for (&self.tracks) |*track| {
            track.reset();
        }
        self.position.store(0, .monotonic);
    }

    pub fn setUseTestTones(self: *AudioEngine, use_test_tones: bool) void {
        self.use_test_tones = use_test_tones;
        log.info("Switched to {s} mode", .{if (use_test_tones) "test tone" else "audio playback"});
    }

    // ==========================================================================
    // Tempo Control
    // ==========================================================================

    pub fn setTempo(self: *AudioEngine, bpm: f32) void {
        const clamped = @max(20.0, @min(300.0, bpm));
        self.tempo.store(clamped, .monotonic);
        log.info("Tempo set to {d:.1} BPM", .{clamped});
    }

    pub fn getTempo(self: *const AudioEngine) f32 {
        return self.tempo.load(.monotonic);
    }

    // ==========================================================================
    // Effects Chain Management
    // ==========================================================================

    /// Get track effects chain
    pub fn getTrackEffects(self: *AudioEngine, track: usize) ?*EffectsChain {
        if (track >= TRACK_COUNT) return null;
        return &self.track_effects[track];
    }

    /// Get master effects chain
    pub fn getMasterEffects(self: *AudioEngine) *EffectsChain {
        return &self.master_effects;
    }

    /// Add effect to track
    pub fn addTrackEffect(self: *AudioEngine, track: usize, effect_type: effects.EffectType) !usize {
        if (track >= TRACK_COUNT) return error.InvalidTrackIndex;
        return self.track_effects[track].addEffect(effect_type);
    }

    /// Add effect to master
    pub fn addMasterEffect(self: *AudioEngine, effect_type: effects.EffectType) !usize {
        return self.master_effects.addEffect(effect_type);
    }

    /// Remove effect from track
    pub fn removeTrackEffect(self: *AudioEngine, track: usize, effect_index: usize) void {
        if (track >= TRACK_COUNT) return;
        self.track_effects[track].removeEffect(effect_index);
    }

    /// Remove effect from master
    pub fn removeMasterEffect(self: *AudioEngine, effect_index: usize) void {
        self.master_effects.removeEffect(effect_index);
    }

    /// Bypass track effects chain
    pub fn setTrackEffectsBypass(self: *AudioEngine, track: usize, bypassed: bool) void {
        if (track >= TRACK_COUNT) return;
        self.track_effects[track].setBypass(bypassed);
    }

    /// Bypass master effects chain
    pub fn setMasterEffectsBypass(self: *AudioEngine, bypassed: bool) void {
        self.master_effects.setBypass(bypassed);
    }

    /// Reset all effects (clear delay lines, filter states, etc.)
    pub fn resetAllEffects(self: *AudioEngine) void {
        for (&self.track_effects) |*chain| {
            chain.reset();
        }
        self.master_effects.reset();
    }
};

test "audio engine init/deinit" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var engine = try AudioEngine.init(allocator, .{
        .sample_rate = 48000,
        .buffer_size = 512,
    });
    defer engine.deinit();

    try testing.expectEqual(@as(u32, 48000), engine.config.sample_rate);
    try testing.expectEqual(@as(u32, 512), engine.config.buffer_size);
}

// =============================================================================
// Comprehensive Tests
// =============================================================================

test "AudioEngine - initial state" {
    const testing = std.testing;

    var engine = try AudioEngine.init(testing.allocator, .{
        .sample_rate = 48000,
        .buffer_size = 512,
    });
    defer engine.deinit();

    // Check transport state
    try testing.expectEqual(@as(u64, 0), engine.getPosition());
    try testing.expect(!engine.isPlaying());
    try testing.expect(!engine.isRecording());

    // Check gain defaults
    try testing.expectApproxEqAbs(@as(f32, 0.75), engine.getMasterGain(), 0.001);
    for (0..AudioEngine.TRACK_COUNT) |i| {
        try testing.expectApproxEqAbs(@as(f32, 0.75), engine.getTrackGain(i), 0.001);
    }

    // Check meter defaults
    try testing.expectApproxEqAbs(@as(f32, 0.0), engine.getMasterMeterLeft(), 0.001);
    try testing.expectApproxEqAbs(@as(f32, 0.0), engine.getMasterMeterRight(), 0.001);
    for (0..AudioEngine.TRACK_COUNT) |i| {
        try testing.expectApproxEqAbs(@as(f32, 0.0), engine.getTrackMeter(i), 0.001);
    }

    // Check mute/solo defaults
    for (0..AudioEngine.TRACK_COUNT) |i| {
        try testing.expect(!engine.getTrackMute(i));
        try testing.expect(!engine.getTrackSolo(i));
        try testing.expect(!engine.getTrackArm(i));
    }
}

test "AudioEngine - setTrackGain clamping" {
    const testing = std.testing;

    var engine = try AudioEngine.init(testing.allocator, .{});
    defer engine.deinit();

    // Gain up to 1.5 is kept as set (the CLI documents 0..1.5); beyond that it is clamped.
    engine.setTrackGain(0, 1.5);
    try testing.expectApproxEqAbs(@as(f32, 1.5), engine.getTrackGain(0), 0.001);
    engine.setTrackGain(0, 2.0);
    try testing.expectApproxEqAbs(@as(f32, 1.5), engine.getTrackGain(0), 0.001);

    engine.setTrackGain(0, -0.5);
    try testing.expectApproxEqAbs(@as(f32, 0.0), engine.getTrackGain(0), 0.001);

    engine.setTrackGain(0, 0.5);
    try testing.expectApproxEqAbs(@as(f32, 0.5), engine.getTrackGain(0), 0.001);

    // Test invalid track index (should be no-op)
    engine.setTrackGain(999, 0.5);
    try testing.expectApproxEqAbs(@as(f32, 0.0), engine.getTrackGain(999), 0.001);
}

test "AudioEngine - setMasterGain clamping" {
    const testing = std.testing;

    var engine = try AudioEngine.init(testing.allocator, .{});
    defer engine.deinit();

    engine.setMasterGain(1.5);
    try testing.expectApproxEqAbs(@as(f32, 1.0), engine.getMasterGain(), 0.001);

    engine.setMasterGain(-0.5);
    try testing.expectApproxEqAbs(@as(f32, 0.0), engine.getMasterGain(), 0.001);

    engine.setMasterGain(0.8);
    try testing.expectApproxEqAbs(@as(f32, 0.8), engine.getMasterGain(), 0.001);
}

test "AudioEngine - setTrackPan clamping" {
    const testing = std.testing;

    var engine = try AudioEngine.init(testing.allocator, .{});
    defer engine.deinit();

    // Test clamping to -1.0 to 1.0
    engine.setTrackPan(0, 1.5);
    try testing.expectApproxEqAbs(@as(f32, 1.0), engine.getTrackPan(0), 0.001);

    engine.setTrackPan(0, -1.5);
    try testing.expectApproxEqAbs(@as(f32, -1.0), engine.getTrackPan(0), 0.001);

    engine.setTrackPan(0, 0.5);
    try testing.expectApproxEqAbs(@as(f32, 0.5), engine.getTrackPan(0), 0.001);

    // Test invalid track index
    engine.setTrackPan(999, 0.5);
    try testing.expectApproxEqAbs(@as(f32, 0.0), engine.getTrackPan(999), 0.001);
}

test "AudioEngine - mute/solo controls" {
    const testing = std.testing;

    var engine = try AudioEngine.init(testing.allocator, .{});
    defer engine.deinit();

    // Test mute
    try testing.expect(!engine.getTrackMute(0));
    engine.setTrackMute(0, true);
    try testing.expect(engine.getTrackMute(0));
    engine.setTrackMute(0, false);
    try testing.expect(!engine.getTrackMute(0));

    // Test solo
    try testing.expect(!engine.getTrackSolo(1));
    engine.setTrackSolo(1, true);
    try testing.expect(engine.getTrackSolo(1));
    engine.setTrackSolo(1, false);
    try testing.expect(!engine.getTrackSolo(1));

    // Test invalid indices
    engine.setTrackMute(999, true);
    try testing.expect(!engine.getTrackMute(999));

    engine.setTrackSolo(999, true);
    try testing.expect(!engine.getTrackSolo(999));
}

test "AudioEngine - record arm controls" {
    const testing = std.testing;

    var engine = try AudioEngine.init(testing.allocator, .{});
    defer engine.deinit();

    try testing.expect(!engine.getTrackArm(0));
    engine.setTrackArm(0, true);
    try testing.expect(engine.getTrackArm(0));
    engine.setTrackArm(0, false);
    try testing.expect(!engine.getTrackArm(0));

    // Test invalid index
    engine.setTrackArm(999, true);
    try testing.expect(!engine.getTrackArm(999));
}

test "AudioEngine - solo logic in process" {
    const testing = std.testing;

    var engine = try AudioEngine.init(testing.allocator, .{
        .sample_rate = 48000,
        .buffer_size = 64,
    });
    defer engine.deinit();

    // When no tracks are soloed, mute should work normally
    var output = @as([128]f32, @splat(0.0)); // 64 stereo frames

    engine.setTrackMute(0, true);
    engine.process(&output);

    // When a track is soloed, only soloed tracks should be audible
    engine.setTrackSolo(1, true);
    engine.process(&output);

    // Track 0 is muted but not relevant since track 1 is soloed
    // Track 1 should be audible
    // Tracks 2 to 7 should be silent (not soloed)
}

test "AudioEngine - metering calculations" {
    const testing = std.testing;

    var engine = try AudioEngine.init(testing.allocator, .{
        .sample_rate = 48000,
        .buffer_size = 64,
    });
    defer engine.deinit();

    // Process with all zeros
    var output = @as([128]f32, @splat(0.0));
    engine.process(&output);

    // Meters should be zero
    try testing.expectApproxEqAbs(@as(f32, 0.0), engine.getMasterMeterLeft(), 0.001);
    try testing.expectApproxEqAbs(@as(f32, 0.0), engine.getMasterMeterRight(), 0.001);
    for (0..AudioEngine.TRACK_COUNT) |i| {
        try testing.expectApproxEqAbs(@as(f32, 0.0), engine.getTrackMeter(i), 0.001);
    }
}

test "AudioEngine - position updates when playing" {
    const testing = std.testing;

    var engine = try AudioEngine.init(testing.allocator, .{
        .sample_rate = 48000,
        .buffer_size = 512,
    });
    defer engine.deinit();

    try testing.expectEqual(@as(u64, 0), engine.getPosition());

    // Position shouldn't update when not playing
    var output = @as([1024]f32, @splat(0.0));
    engine.process(&output);
    try testing.expectEqual(@as(u64, 0), engine.getPosition());

    // Position should update when playing
    engine.playing.store(true, .monotonic);
    engine.process(&output);
    try testing.expectEqual(@as(u64, 512), engine.getPosition());

    engine.process(&output);
    try testing.expectEqual(@as(u64, 1024), engine.getPosition());
}

test "AudioEngine - position advances by processed frames, not configured buffer size" {
    const testing = std.testing;

    var engine = try AudioEngine.init(testing.allocator, .{
        .sample_rate = 48000,
        .buffer_size = 512,
    });
    defer engine.deinit();

    engine.position.store(0, .monotonic);
    engine.playing.store(true, .monotonic);

    // Backend delivers 1024-frame stereo blocks although buffer_size is 512.
    var output = @as([2048]f32, @splat(0.0));
    engine.process(&output);
    try testing.expectEqual(@as(u64, 1024), engine.getPosition());

    var small = @as([128]f32, @splat(0.0));
    engine.process(&small);
    try testing.expectEqual(@as(u64, 1088), engine.getPosition());
}

test "AudioEngine - resetTracks" {
    const testing = std.testing;

    var engine = try AudioEngine.init(testing.allocator, .{
        .sample_rate = 48000,
        .buffer_size = 512,
    });
    defer engine.deinit();

    // Simulate playback
    engine.position.store(10000, .monotonic);
    try testing.expectEqual(@as(u64, 10000), engine.getPosition());

    engine.resetTracks();
    try testing.expectEqual(@as(u64, 0), engine.getPosition());
}

test "AudioEngine - track management invalid index" {
    const testing = std.testing;

    var engine = try AudioEngine.init(testing.allocator, .{});
    defer engine.deinit();

    // loadTrackFile with invalid index should error
    try testing.expectError(
        error.InvalidTrackIndex,
        engine.loadTrackFile(999, "test.wav"),
    );
}

test "AudioEngine - effects chain access" {
    const testing = std.testing;

    var engine = try AudioEngine.init(testing.allocator, .{});
    defer engine.deinit();

    // Test track effects access
    const track_fx = engine.getTrackEffects(0);
    try testing.expect(track_fx != null);

    // Test invalid track index
    const invalid_fx = engine.getTrackEffects(999);
    try testing.expect(invalid_fx == null);

    // Test master effects access
    const master_fx = engine.getMasterEffects();
    _ = master_fx;
}

test "AudioEngine - effects bypass controls" {
    const testing = std.testing;

    var engine = try AudioEngine.init(testing.allocator, .{});
    defer engine.deinit();

    // Set track effects bypass
    engine.setTrackEffectsBypass(0, true);
    try testing.expect(engine.track_effects[0].bypassed);

    engine.setTrackEffectsBypass(0, false);
    try testing.expect(!engine.track_effects[0].bypassed);

    // Set master effects bypass
    engine.setMasterEffectsBypass(true);
    try testing.expect(engine.master_effects.bypassed);

    engine.setMasterEffectsBypass(false);
    try testing.expect(!engine.master_effects.bypassed);

    // Test invalid track index (should be no-op)
    engine.setTrackEffectsBypass(999, true);
}

test "AudioEngine - resetAllEffects" {
    const testing = std.testing;

    var engine = try AudioEngine.init(testing.allocator, .{});
    defer engine.deinit();

    // Should not crash when called
    engine.resetAllEffects();

    // All effects should be reset (internal state cleared)
    // We can't easily test internal state, but ensure it doesn't crash
}

test "AudioEngine - master gain application in process" {
    const testing = std.testing;

    var engine = try AudioEngine.init(testing.allocator, .{
        .sample_rate = 48000,
        .buffer_size = 64,
    });
    defer engine.deinit();

    // Set master gain to 0 - output should be silent
    engine.setMasterGain(0.0);

    var output = @as([128]f32, @splat(1.0)); // Pre-fill with non-zero
    engine.process(&output);

    for (output) |sample| {
        try testing.expectApproxEqAbs(@as(f32, 0.0), sample, 0.001);
    }
}

test "AudioEngine - track count constant" {
    const testing = std.testing;

    // Verify TRACK_COUNT is as expected
    try testing.expectEqual(@as(usize, 8), AudioEngine.TRACK_COUNT);
}

test "AudioEngine - use test tones flag" {
    const testing = std.testing;

    var engine = try AudioEngine.init(testing.allocator, .{});
    defer engine.deinit();

    try testing.expect(engine.use_test_tones);

    engine.setUseTestTones(false);
    try testing.expect(!engine.use_test_tones);

    engine.setUseTestTones(true);
    try testing.expect(engine.use_test_tones);
}

test "AudioEngine - CPU usage accessor" {
    const testing = std.testing;

    var engine = try AudioEngine.init(testing.allocator, .{});
    defer engine.deinit();

    const cpu_usage = engine.getCpuUsage();
    try testing.expectApproxEqAbs(@as(f32, 0.0), cpu_usage, 0.001);
}

test "AudioEngine - instrument note is audible in engine mix" {
    const testing = std.testing;

    var engine = try AudioEngine.init(testing.allocator, .{
        .sample_rate = 48000,
        .buffer_size = 512,
    });
    defer engine.deinit();

    const types = [_]u8{ 0, 1 }; // keys, wavetable_synth
    for (types, 0..) |t, idx| {
        const inst_type = @import("../instruments/instruments.zig").getInstrumentType(t).?;
        try engine.tracks[idx].setInstrument(inst_type);
        engine.tracks[idx].noteOn(60, 100);

        var output: [1024]f32 = @splat(0.0); // 512 stereo frames
        engine.process(&output);

        var peak: f32 = 0.0;
        for (output) |s| peak = @max(peak, @abs(s));
        std.debug.print("engine track {d}: peak={d}\n", .{ idx, peak });
        try testing.expect(peak > 0.001);
        engine.tracks[idx].noteOff(60);
    }
}

test "AudioEngine - hardware MIDI note routes to selected track instrument" {
    const testing = std.testing;

    var engine = try AudioEngine.init(testing.allocator, .{ .sample_rate = 48000, .buffer_size = 512 });
    defer engine.deinit();
    engine.setUseTestTones(false);
    engine.setMasteringEnabled(false);

    const inst_type = @import("../instruments/instruments.zig").getInstrumentType(0).?;
    try engine.tracks[2].setInstrument(inst_type);
    engine.setMidiInputTrack(2);
    try testing.expectEqual(@as(usize, 2), engine.midi_input_track.load(.monotonic));

    try testing.expect(engine.midi_ring.push(.{ .note = 60, .velocity = 100, .on = true }));
    var output: [1024]f32 = @splat(0.0);
    engine.process(&output);
    try testing.expectEqual(@as(?note_ring.NoteEvent, null), engine.midi_ring.pop());
    var peak: f32 = 0.0;
    for (output) |s| peak = @max(peak, @abs(s));
    try testing.expect(peak > 0.001);
    try testing.expect(engine.getTrackMeter(2) > 0.001);

    // Note off then silence the instrument tail check is not needed; the event just drains.
    try testing.expect(engine.midi_ring.push(.{ .note = 60, .velocity = 0, .on = false }));
    engine.process(&output);
    try testing.expectEqual(@as(?note_ring.NoteEvent, null), engine.midi_ring.pop());
}

test "AudioEngine - notes queued from another thread while rendering all reach the instrument" {
    const testing = std.testing;
    var engine = try AudioEngine.init(testing.allocator, .{ .sample_rate = 48000, .buffer_size = 64, .backend_preference = "none" });
    defer engine.deinit();
    engine.setUseTestTones(false);
    engine.setMasteringEnabled(false);
    const inst_type = @import("../instruments/instruments.zig").getInstrumentType(0).?;
    try engine.tracks[3].setInstrument(inst_type);

    const notes = 2000;
    const Producer = struct {
        fn run(eng: *AudioEngine) void {
            var sent: usize = 0;
            while (sent < notes) {
                const note: u8 = @intCast(36 + sent % 48);
                if (!eng.queueNoteOn(3, note, 90)) {
                    std.atomic.spinLoopHint();
                    continue;
                }
                while (!eng.queueNoteOff(3, note)) std.atomic.spinLoopHint();
                sent += 1;
            }
        }
    };
    try testing.expect(!engine.queueNoteOn(AudioEngine.TRACK_COUNT, 60, 100));
    try testing.expect(!engine.queueNoteOn(0, 128, 100));

    const thread = try std.Thread.spawn(.{}, Producer.run, .{&engine});
    var output: [128]f32 = @splat(0.0);
    var blocks: usize = 0;
    while (blocks < 100_000) : (blocks += 1) {
        engine.process(&output);
        if (engine.control_events.read_pos >= 2 * notes) break;
    }
    thread.join();
    engine.process(&output);
    try testing.expectEqual(@as(usize, 2 * notes), engine.control_events.read_pos);
    try testing.expect(engine.tracks[3].is_active);
    for (output) |s| try testing.expect(std.math.isFinite(s));
}

/// Renders `frames` frames offline in blocks of `block` frames with one Keys note on `track` from
/// `note_beat` for `length` beats (120 bpm, 48 kHz: 24000 frames per beat). Returns the left channel.
fn renderClipNote(allocator: std.mem.Allocator, track: usize, block: usize, frames: usize, note_beat: f64, length: f64) ![]f32 {
    var engine = try AudioEngine.init(allocator, .{ .sample_rate = 48000, .buffer_size = @intCast(block), .backend_preference = "none" });
    defer engine.deinit();
    engine.setUseTestTones(false);
    engine.setMasteringEnabled(false);
    try engine.tracks[track].setInstrument(@import("../instruments/instruments.zig").getInstrumentType(0).?);

    midi_clip.midi_clip_clear(@intCast(track));
    defer midi_clip.midi_clip_clear(@intCast(track));
    midi_clip.midi_clip_set_start_beat(@intCast(track), 0.0);
    if (midi_clip.midi_clip_add_note(@intCast(track), note_beat, length, 60, 100) == 0) return error.AddNoteFailed;

    const left = try allocator.alloc(f32, frames);
    errdefer allocator.free(left);
    var buf: [2 * AudioEngine.MAX_BLOCK_FRAMES]f32 = undefined;
    const state = engine.beginOfflineRender();
    defer engine.endOfflineRender(state);
    var done: usize = 0;
    while (done < frames) {
        const n = @min(block, frames - done);
        engine.renderOffline(buf[0 .. 2 * n], done);
        for (0..n) |i| left[done + i] = buf[2 * i];
        done += n;
    }
    return left;
}

fn firstAbove(samples: []const f32, threshold: f32) ?usize {
    for (samples, 0..) |s, i| {
        if (@abs(s) > threshold) return i;
    }
    return null;
}

test "AudioEngine - clip notes start and stop at their sample, whatever the block size" {
    const testing = std.testing;
    const allocator = testing.allocator;
    // Beat 0.125 is frame 3000; the note lasts a quarter beat (6000 frames), so it ends at 9000.
    const note_frame = 3000;
    const blocks = [_]usize{ 64, 100, 128, 512, 1000, 2048 };
    const reference = try renderClipNote(allocator, 5, 1, 12000, 0.125, 0.25);
    defer allocator.free(reference);
    const onset = firstAbove(reference, 1e-7).?;
    try testing.expect(onset >= note_frame and onset <= note_frame + 2);

    for (blocks) |block| {
        const rendered = try renderClipNote(allocator, 5, block, 12000, 0.125, 0.25);
        defer allocator.free(rendered);
        try testing.expectEqual(onset, firstAbove(rendered, 1e-7).?);
        // Identical up to the release, so note-off lands on the same sample too.
        try testing.expectEqualSlices(f32, reference, rendered);
    }
}

test "AudioEngine - hardware MIDI note on track without instrument is dropped" {
    const testing = std.testing;

    var engine = try AudioEngine.init(testing.allocator, .{ .sample_rate = 48000, .buffer_size = 512 });
    defer engine.deinit();
    engine.setUseTestTones(false);
    engine.setMasteringEnabled(false);

    // Instrument on track 1, but input selected on track 0 (no instrument).
    const inst_type = @import("../instruments/instruments.zig").getInstrumentType(0).?;
    try engine.tracks[1].setInstrument(inst_type);
    try testing.expectEqual(@as(usize, 0), engine.midi_input_track.load(.monotonic));

    try testing.expect(engine.midi_ring.push(.{ .note = 60, .velocity = 100, .on = true }));
    var output: [1024]f32 = @splat(0.0);
    engine.process(&output);
    try testing.expectEqual(@as(?note_ring.NoteEvent, null), engine.midi_ring.pop());
    for (output) |s| try testing.expectApproxEqAbs(@as(f32, 0.0), s, 0.0001);
    try testing.expectEqual(@as(f32, 0.0), engine.getTrackMeter(1));

    // Out-of-range selection is ignored.
    engine.setMidiInputTrack(AudioEngine.TRACK_COUNT);
    try testing.expectEqual(@as(usize, 0), engine.midi_input_track.load(.monotonic));
}

test "AudioEngine - track 8 renders audio" {
    const testing = std.testing;

    var engine = try AudioEngine.init(testing.allocator, .{
        .sample_rate = 48000,
        .buffer_size = 64,
    });
    defer engine.deinit();

    const last = AudioEngine.TRACK_COUNT - 1;
    var samples: [256]f32 = @splat(0.5);
    try engine.tracks[last].loadFromBuffer(&samples, 2, 48000);
    engine.setUseTestTones(false);
    engine.setMasteringEnabled(false); // mastering adds latency; this test reads the first block

    var output = @as([128]f32, @splat(0.0));
    engine.process(&output);

    var peak: f32 = 0.0;
    for (output) |sample| peak = @max(peak, @abs(sample));
    try testing.expect(peak > 0.01);
    try testing.expect(engine.getTrackMeter(last) > 0.01);
    try testing.expectApproxEqAbs(@as(f32, 0.0), engine.getTrackMeter(0), 0.001);
}

/// Engine with track 1 playing a constant 1.0 signal, so the output level equals the gain.
fn initAutomationEngine(allocator: std.mem.Allocator) !AudioEngine {
    var engine = try AudioEngine.init(allocator, .{ .sample_rate = 48000, .buffer_size = 64 });
    errdefer engine.deinit();
    const samples = try allocator.alloc(f32, 2 * 48000 * 20);
    defer allocator.free(samples);
    @memset(samples, 1.0);
    try engine.tracks[0].loadFromBuffer(samples, 2, 48000);
    engine.setUseTestTones(false);
    engine.setMasterGain(1.0);
    engine.setTrackGain(0, 0.5);
    // These tests read exact sample values from the first frames; mastering adds latency.
    engine.setMasteringEnabled(false);
    return engine;
}

/// Plays one 64-frame block at `beat` (120 bpm, 48 kHz: one beat is 24000 frames) and returns
/// the first frame's left sample.
fn levelAtBeat(engine: *AudioEngine, beat: f64) f32 {
    var output: [128]f32 = @splat(0.0);
    engine.position.store(@intFromFloat(beat * 24000.0), .monotonic);
    engine.tracks[0].clip.?.seek(@intFromFloat(beat * 24000.0));
    engine.playing.store(true, .monotonic);
    engine.process(&output);
    engine.playing.store(false, .monotonic);
    return output[0];
}

test "AudioEngine - gain automation fades 0 to 1 over 4 beats" {
    const testing = std.testing;
    var engine = try initAutomationEngine(testing.allocator);
    defer engine.deinit();

    try engine.addAutomationPoint(.track_gain, 0, 0.0, 0.0);
    try engine.addAutomationPoint(.track_gain, 0, 4.0, 1.0);

    try testing.expectApproxEqAbs(@as(f32, 0.5), levelAtBeat(&engine, 2.0), 0.01);
    try testing.expectApproxEqAbs(@as(f32, 0.25), levelAtBeat(&engine, 1.0), 0.01);
}

test "AudioEngine - automation holds the last value after the final point" {
    const testing = std.testing;
    var engine = try initAutomationEngine(testing.allocator);
    defer engine.deinit();

    try engine.addAutomationPoint(.track_gain, 0, 0.0, 0.0);
    try engine.addAutomationPoint(.track_gain, 0, 4.0, 0.8);

    try testing.expectApproxEqAbs(@as(f32, 0.8), levelAtBeat(&engine, 6.0), 0.01);
    try testing.expectApproxEqAbs(@as(f32, 0.8), levelAtBeat(&engine, 12.0), 0.01);
}

test "AudioEngine - clearing a lane returns the manual value, and stopped playback ignores lanes" {
    const testing = std.testing;
    var engine = try initAutomationEngine(testing.allocator);
    defer engine.deinit();

    try engine.addAutomationPoint(.track_gain, 0, 0.0, 0.0);
    try engine.addAutomationPoint(.track_gain, 0, 4.0, 1.0);
    try testing.expectApproxEqAbs(@as(f32, 0.5), levelAtBeat(&engine, 2.0), 0.01);

    // Stopped: the manual value (0.5) is used even though the lane says 0.0 at beat 0.
    var output: [128]f32 = @splat(0.0);
    engine.position.store(0, .monotonic);
    engine.process(&output);
    try testing.expectApproxEqAbs(@as(f32, 0.5), output[0], 0.01);

    try engine.clearAutomation(.track_gain, 0);
    try testing.expectApproxEqAbs(@as(f32, 0.5), levelAtBeat(&engine, 1.0), 0.01);
    try testing.expectApproxEqAbs(@as(f32, 0.5), engine.getTrackGain(0), 0.0001);
}

test "AudioEngine - master gain automation" {
    const testing = std.testing;
    var engine = try initAutomationEngine(testing.allocator);
    defer engine.deinit();

    try engine.addAutomationPoint(.master_gain, 0, 0.0, 0.0);
    try engine.addAutomationPoint(.master_gain, 0, 4.0, 1.0);
    // Track gain 0.5 times master 0.5 at beat 2.
    try testing.expectApproxEqAbs(@as(f32, 0.25), levelAtBeat(&engine, 2.0), 0.01);
    try engine.clearAutomation(.master_gain, 0);
    // Back to the manual master (1.0): ramped from where the lane left it, not stepped...
    try testing.expectApproxEqAbs(@as(f32, 0.25), levelAtBeat(&engine, 2.0), 0.01);
    // ...and there once the 10 ms ramp has run.
    for (0..8) |_| _ = levelAtBeat(&engine, 2.0);
    try testing.expectApproxEqAbs(@as(f32, 0.5), levelAtBeat(&engine, 2.0), 0.01);
}

test "AudioEngine - pan automation moves the signal to one side" {
    const testing = std.testing;
    var engine = try initAutomationEngine(testing.allocator);
    defer engine.deinit();

    try engine.addAutomationPoint(.track_pan, 0, 0.0, -1.0);
    try engine.addAutomationPoint(.track_pan, 0, 4.0, 1.0);
    var output: [128]f32 = @splat(0.0);
    engine.position.store(0, .monotonic);
    engine.playing.store(true, .monotonic);
    engine.process(&output);
    // Full left at beat 0: right channel silent, left at the track gain.
    try testing.expectApproxEqAbs(@as(f32, 0.5), output[0], 0.01);
    try testing.expectApproxEqAbs(@as(f32, 0.0), output[1], 0.01);
}

test "AudioEngine - reverb wet automation applies while playing and restores when stopped" {
    const testing = std.testing;
    var engine = try initAutomationEngine(testing.allocator);
    defer engine.deinit();

    try testing.expect(!engine.trackHasReverb(0));
    _ = try engine.track_effects[0].addEffect(.reverb);
    try testing.expect(engine.trackHasReverb(0));
    engine.track_effects[0].getEffect(0).?.setParameter(REVERB_WET_PARAM, 0.2);

    try engine.addAutomationPoint(.track_wet, 0, 0.0, 0.0);
    try engine.addAutomationPoint(.track_wet, 0, 4.0, 1.0);
    _ = levelAtBeat(&engine, 2.0);
    // levelAtBeat stops the transport after its block; the next block restores the manual wet.
    var output: [128]f32 = @splat(0.0);
    engine.playing.store(true, .monotonic);
    engine.position.store(2 * 24000, .monotonic);
    engine.process(&output);
    try testing.expectApproxEqAbs(@as(f32, 0.5), engine.track_effects[0].getEffect(0).?.getParameter(REVERB_WET_PARAM).?.value, 0.01);
    engine.playing.store(false, .monotonic);
    engine.process(&output);
    try testing.expectApproxEqAbs(@as(f32, 0.2), engine.track_effects[0].getEffect(0).?.getParameter(REVERB_WET_PARAM).?.value, 0.001);
}

/// Processes `blocks` stopped 64-frame blocks and appends the left channel to `out`.
fn collectLeft(engine: *AudioEngine, blocks: usize, out: *std.ArrayList(f32), allocator: std.mem.Allocator) !void {
    for (0..blocks) |_| {
        var output: [128]f32 = @splat(0.0);
        engine.process(&output);
        for (0..64) |i| try out.append(allocator, output[2 * i]);
    }
}

/// Largest change between neighbouring samples.
fn maxStep(samples: []const f32) f32 {
    var worst: f32 = 0.0;
    for (samples[1..], samples[0 .. samples.len - 1]) |b, a| worst = @max(worst, @abs(b - a));
    return worst;
}

test "AudioEngine - fader, master and pan moves are ramped per sample, not stepped" {
    const testing = std.testing;
    const allocator = testing.allocator;
    var engine = try initAutomationEngine(allocator);
    defer engine.deinit();
    // 10 ms at 48 kHz.
    const ramp_frames = 480;

    var left: std.ArrayList(f32) = .empty;
    defer left.deinit(allocator);
    try collectLeft(&engine, 4, &left, allocator);
    try testing.expectApproxEqAbs(@as(f32, 0.5), left.items[left.items.len - 1], 1e-6);

    // Track fader 0.5 -> 1.0: no jump bigger than one ramp step, and it arrives within 10 ms.
    const before = left.items.len - 1;
    engine.setTrackGain(0, 1.0);
    try collectLeft(&engine, 16, &left, allocator);
    try testing.expect(maxStep(left.items[before..]) <= 0.5 / @as(f32, ramp_frames) + 1e-5);
    try testing.expectApproxEqAbs(@as(f32, 1.0), left.items[before + ramp_frames], 1e-5);
    try testing.expectApproxEqAbs(@as(f32, 1.0), left.items[left.items.len - 1], 1e-6);

    // Master 1.0 -> 0.25.
    const master_start = left.items.len - 1;
    engine.setMasterGain(0.25);
    try collectLeft(&engine, 16, &left, allocator);
    try testing.expect(maxStep(left.items[master_start..]) <= 0.75 / @as(f32, ramp_frames) + 1e-5);
    try testing.expectApproxEqAbs(@as(f32, 0.25), left.items[left.items.len - 1], 1e-6);

    // Pan hard right: the left channel fades out instead of cutting.
    const pan_start = left.items.len - 1;
    engine.setTrackPan(0, 1.0);
    try collectLeft(&engine, 16, &left, allocator);
    try testing.expect(maxStep(left.items[pan_start..]) <= 0.25 / @as(f32, ramp_frames) + 1e-5);
    try testing.expectApproxEqAbs(@as(f32, 0.0), left.items[left.items.len - 1], 1e-6);
}

test "AudioEngine - the default buffer is 128 frames everywhere it is chosen" {
    const testing = std.testing;
    // 128 frames is 2.7 ms at 48 kHz, the live-performance target.
    try testing.expectEqual(@as(u32, 128), (EngineConfig{}).buffer_size);
    try testing.expectEqual(@as(u32, 128), @import("../config/config.zig").Config.default().audio.buffer_size);
    try testing.expectEqual(@as(u32, 128), (@import("../config/audio_settings.zig").AudioSettings{}).buffer_size);
    try testing.expectEqual(@as(u32, 128), (@import("../system/preflight.zig").Options{}).buffer_size);
    const caps = detect.detect();
    if (caps.os != .unknown) {
        try testing.expectEqual(@as(u32, 128), caps.default_buffer_size);
        try testing.expect(isListed(128, caps.buffer_sizes));
    }

    // The engine and the PipeWire re-blocker run a 128-frame engine at a 1024-frame graph
    // quantum and at a 64-frame one without gaps.
    var engine = try AudioEngine.init(testing.allocator, .{ .backend_preference = "none" });
    defer engine.deinit();
    engine.setMasteringEnabled(false);
    engine.playing.store(true, .monotonic);
    const pipewire = @import("pipewire.zig");
    var adapter = try pipewire.BlockAdapter.init(testing.allocator, engine.config.buffer_size, 2);
    defer adapter.deinit(testing.allocator);
    adapter.engine.store(&engine, .release);
    adapter.process_fn.store(AudioEngine.processWrapper, .release);
    var out: [2 * 1024]f32 = undefined;
    adapter.fill(&out);
    adapter.fill(out[0 .. 2 * 64]);
    try testing.expectEqual(@as(u64, 1024 + 128), engine.getPosition());
}

/// Renders 1.5 beats of a noise clip through a reverb whose wet amount is automated 0 -> 1 over
/// the first beat, offline in blocks of `block` frames. Returns the interleaved output.
fn renderWetSweep(allocator: std.mem.Allocator, block: usize) ![]f32 {
    var engine = try AudioEngine.init(allocator, .{ .sample_rate = 48000, .buffer_size = @intCast(block), .backend_preference = "none" });
    defer engine.deinit();
    engine.setUseTestTones(false);
    engine.setMasteringEnabled(false);
    const frames = 36000;
    const noise = try allocator.alloc(f32, 2 * frames);
    defer allocator.free(noise);
    var prng = std.Random.DefaultPrng.init(7);
    for (noise) |*s| s.* = prng.random().float(f32) - 0.5;
    try engine.tracks[0].loadFromBuffer(noise, 2, 48000);
    _ = try engine.track_effects[0].addEffect(.reverb);
    try engine.addAutomationPoint(.track_wet, 0, 0.0, 0.0);
    try engine.addAutomationPoint(.track_wet, 0, 1.0, 1.0);

    const out = try allocator.alloc(f32, 2 * frames);
    errdefer allocator.free(out);
    const state = engine.beginOfflineRender();
    defer engine.endOfflineRender(state);
    var done: usize = 0;
    while (done < frames) {
        const n = @min(block, frames - done);
        engine.renderOffline(out[2 * done .. 2 * (done + n)], done);
        done += n;
    }
    return out;
}

test "AudioEngine - effect automation follows a fixed 32-sample grid, whatever the block size" {
    const testing = std.testing;
    const allocator = testing.allocator;
    const reference = try renderWetSweep(allocator, 32);
    defer allocator.free(reference);
    for ([_]usize{ 64, 100, 128, 512, 1000, 2048 }) |block| {
        const rendered = try renderWetSweep(allocator, block);
        defer allocator.free(rendered);
        try testing.expectEqualSlices(f32, reference, rendered);
    }
}

test "AudioEngine - automation argument checks" {
    const testing = std.testing;
    var engine = try AudioEngine.init(testing.allocator, .{ .sample_rate = 48000, .buffer_size = 64 });
    defer engine.deinit();
    try testing.expectError(error.InvalidTrack, engine.addAutomationPoint(.track_gain, 8, 0.0, 0.5));
    try testing.expectError(error.InvalidValue, engine.addAutomationPoint(.track_gain, 0, -1.0, 0.5));
    try testing.expectError(error.InvalidValue, engine.addAutomationPoint(.track_gain, 0, 0.0, std.math.nan(f32)));
    try engine.addAutomationPoint(.master_gain, 99, 0.0, 0.5);
}

// export.zig is not reachable from test_main.zig; pull its tests into the engine test run.
test {
    _ = @import("automation.zig");
    _ = @import("export.zig");
}
