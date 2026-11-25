//! C API wrapper for audio engine
//! Allows C code (GTK UI) to call into Zig audio engine

const std = @import("std");
const AudioEngine = @import("engine.zig").AudioEngine;
const SettingError = @import("engine.zig").SettingError;
const instruments = @import("../instruments/instruments.zig");
const Instrument = instruments.Instrument;
const dsp = @import("../dsp/resample.zig");
const eq_presets = @import("../effects/eq_presets.zig");

// Helper functions to reduce pointer casting duplication
inline fn castEngine(engine: ?*anyopaque) ?*AudioEngine {
    return if (engine) |eng|
        @ptrCast(@alignCast(eng))
    else
        null;
}

inline fn castEngineConst(engine: ?*anyopaque) ?*const AudioEngine {
    return if (engine) |eng|
        @ptrCast(@alignCast(eng))
    else
        null;
}

pub export fn audio_engine_start(engine: ?*anyopaque) callconv(.c) c_int {
    if (castEngine(engine)) |eng| {
        eng.start() catch |err| {
            std.log.err("Failed to start audio engine: {}", .{err});
            return -1;
        };
        return 0;
    }
    return -1;
}

pub export fn audio_engine_stop(engine: ?*anyopaque) callconv(.c) void {
    if (castEngine(engine)) |eng| {
        eng.stop();
    }
}

pub export fn audio_engine_is_playing(engine: ?*anyopaque) callconv(.c) c_int {
    if (castEngine(engine)) |eng| {
        return if (eng.playing.load(.monotonic)) 1 else 0;
    }
    return 0;
}

pub export fn audio_engine_set_track_gain(engine: ?*anyopaque, track: c_int, gain: f32) callconv(.c) void {
    if (castEngine(engine)) |eng| {
        eng.setTrackGain(@intCast(track), gain);
    }
}

pub export fn audio_engine_get_track_gain(engine: ?*anyopaque, track: c_int) callconv(.c) f32 {
    if (castEngineConst(engine)) |eng| {
        return eng.getTrackGain(@intCast(track));
    }
    return 0.0;
}

pub export fn audio_engine_set_track_pan(engine: ?*anyopaque, track: c_int, pan: f32) callconv(.c) void {
    if (castEngine(engine)) |eng| {
        eng.setTrackPan(@intCast(track), pan);
    }
}

pub export fn audio_engine_get_track_pan(engine: ?*anyopaque, track: c_int) callconv(.c) f32 {
    if (castEngineConst(engine)) |eng| {
        return eng.getTrackPan(@intCast(track));
    }
    return 0.0;
}

/// Adds an automation point. target: 0=track gain, 1=track pan, 2=track reverb wet, 3=master gain.
/// Returns 0, -1 for a bad argument or engine, -2 when the lane is full.
pub export fn audio_engine_automation_add(engine: ?*anyopaque, target: c_int, track: c_int, beat: f64, value: f32) callconv(.c) c_int {
    const eng = castEngine(engine) orelse return -1;
    const kind = automationTarget(target) orelse return -1;
    if (track < 0) return -1;
    eng.addAutomationPoint(kind, @intCast(track), beat, value) catch |err| switch (err) {
        error.LaneFull => return -2,
        error.InvalidTrack, error.InvalidValue => return -1,
    };
    return 0;
}

/// Removes every point of a lane. Same targets as audio_engine_automation_add. Returns 0 or -1.
pub export fn audio_engine_automation_clear(engine: ?*anyopaque, target: c_int, track: c_int) callconv(.c) c_int {
    const eng = castEngine(engine) orelse return -1;
    const kind = automationTarget(target) orelse return -1;
    if (track < 0) return -1;
    eng.clearAutomation(kind, @intCast(track)) catch return -1;
    return 0;
}

/// 1 when the track has a reverb effect whose wet amount can be automated, otherwise 0.
pub export fn audio_engine_track_has_reverb(engine: ?*anyopaque, track: c_int) callconv(.c) c_int {
    const eng = castEngine(engine) orelse return 0;
    if (track < 0) return 0;
    return if (eng.trackHasReverb(@intCast(track))) 1 else 0;
}

fn automationTarget(target: c_int) ?AudioEngine.AutomationTarget {
    return switch (target) {
        0 => .track_gain,
        1 => .track_pan,
        2 => .track_wet,
        3 => .master_gain,
        else => null,
    };
}

pub export fn audio_engine_set_master_gain(engine: ?*anyopaque, gain: f32) callconv(.c) void {
    if (castEngine(engine)) |eng| {
        eng.setMasterGain(gain);
    }
}

pub export fn audio_engine_set_track_mute(engine: ?*anyopaque, track: c_int, muted: c_int) callconv(.c) void {
    if (castEngine(engine)) |eng| {
        eng.setTrackMute(@intCast(track), muted != 0);
    }
}

pub export fn audio_engine_set_track_solo(engine: ?*anyopaque, track: c_int, soloed: c_int) callconv(.c) void {
    if (castEngine(engine)) |eng| {
        eng.setTrackSolo(@intCast(track), soloed != 0);
    }
}

pub export fn audio_engine_get_track_mute(engine: ?*anyopaque, track: c_int) callconv(.c) c_int {
    return if (castEngineConst(engine)) |eng|
        if (eng.getTrackMute(@intCast(track))) 1 else 0
    else
        0;
}

pub export fn audio_engine_get_track_solo(engine: ?*anyopaque, track: c_int) callconv(.c) c_int {
    return if (castEngineConst(engine)) |eng|
        if (eng.getTrackSolo(@intCast(track))) 1 else 0
    else
        0;
}

pub export fn audio_engine_set_track_arm(engine: ?*anyopaque, track: c_int, armed: c_int) callconv(.c) void {
    if (castEngine(engine)) |eng| {
        eng.setTrackArm(@intCast(track), armed != 0);
    }
}

pub export fn audio_engine_get_track_arm(engine: ?*anyopaque, track: c_int) callconv(.c) c_int {
    return if (castEngineConst(engine)) |eng|
        if (eng.getTrackArm(@intCast(track))) 1 else 0
    else
        0;
}

export fn audio_engine_get_track_meter(engine: ?*anyopaque, track: c_int) callconv(.c) f32 {
    return if (castEngineConst(engine)) |eng|
        eng.getTrackMeter(@intCast(track))
    else
        0.0;
}

export fn audio_engine_get_master_meter_left(engine: ?*anyopaque) callconv(.c) f32 {
    return if (castEngineConst(engine)) |eng|
        eng.getMasterMeterLeft()
    else
        0.0;
}

export fn audio_engine_get_master_meter_right(engine: ?*anyopaque) callconv(.c) f32 {
    return if (castEngineConst(engine)) |eng|
        eng.getMasterMeterRight()
    else
        0.0;
}

// =============================================================================
// Instrument API
// =============================================================================

/// Get number of available instrument types
pub export fn audio_engine_get_instrument_type_count() callconv(.c) c_int {
    return @intCast(instruments.getInstrumentTypeCount());
}

/// Get instrument type name by index
pub export fn audio_engine_get_instrument_type_name(index: c_int) callconv(.c) [*:0]const u8 {
    if (instruments.getInstrumentType(@intCast(index))) |inst_type| {
        return @ptrCast(inst_type.name().ptr);
    }
    return "Unknown";
}

/// Instrument type selected by a name (case and spaces ignored), or -1.
pub export fn audio_engine_find_instrument_type(name: [*:0]const u8) callconv(.c) c_int {
    const found = instruments.instrument_types.fromName(std.mem.span(name)) orelse return -1;
    return @backingInt(found);
}

/// Set instrument on a track
pub export fn audio_engine_set_track_instrument(engine: ?*anyopaque, track: c_int, instrument_type: c_int) callconv(.c) c_int {
    if (castEngine(engine)) |eng| {
        const inst_type = instruments.getInstrumentType(@intCast(instrument_type)) orelse return -1;
        eng.tracks[@intCast(track)].setInstrument(inst_type) catch return -1;
        return 0;
    }
    return -1;
}

/// Remove instrument from a track
export fn audio_engine_remove_track_instrument(engine: ?*anyopaque, track: c_int) callconv(.c) void {
    if (castEngine(engine)) |eng| {
        eng.tracks[@intCast(track)].removeInstrument();
    }
}

/// Check if track has an instrument
export fn audio_engine_track_has_instrument(engine: ?*anyopaque, track: c_int) callconv(.c) c_int {
    if (castEngineConst(engine)) |eng| {
        return if (eng.tracks[@intCast(track)].getInstrument() != null) 1 else 0;
    }
    return 0;
}

/// Engine instrument type of the track's instrument, or -1 when it has none.
pub export fn audio_engine_get_track_instrument_type(engine: ?*anyopaque, track: c_int) callconv(.c) c_int {
    if (castEngineConst(engine)) |eng| {
        if (eng.tracks[@intCast(track)].instrument_type) |t| return @backingInt(t);
    }
    return -1;
}

/// Instrument name for a track: the listed type name when the type is known (so it can be given back to
/// `set N instrument`), otherwise the instrument's own display name.
pub export fn audio_engine_get_track_instrument_name(engine: ?*anyopaque, track: c_int) callconv(.c) [*:0]const u8 {
    if (castEngineConst(engine)) |eng| {
        if (eng.tracks[@intCast(track)].instrument_type) |known| {
            return @ptrCast(known.name().ptr);
        }
        if (eng.tracks[@intCast(track)].getInstrument()) |inst| {
            return @ptrCast(inst.name.ptr);
        }
    }
    return "None";
}

/// Queue a note on for the track's instrument; the audio thread plays it at its next block.
/// Out-of-range tracks, notes or velocities are ignored.
pub export fn audio_engine_note_on(engine: ?*anyopaque, track: c_int, note: c_int, velocity: c_int) callconv(.c) void {
    const eng = castEngine(engine) orelse return;
    if (track < 0 or note < 0 or note > 127 or velocity < 0 or velocity > 127) return;
    _ = eng.queueNoteOn(@intCast(track), @intCast(note), @intCast(velocity));
}

/// Queue a note off for the track's instrument (applied by the audio thread).
pub export fn audio_engine_note_off(engine: ?*anyopaque, track: c_int, note: c_int) callconv(.c) void {
    const eng = castEngine(engine) orelse return;
    if (track < 0 or note < 0 or note > 127) return;
    _ = eng.queueNoteOff(@intCast(track), @intCast(note));
}

/// Queue all notes off for the track's instrument (applied by the audio thread).
pub export fn audio_engine_all_notes_off(engine: ?*anyopaque, track: c_int) callconv(.c) void {
    const eng = castEngine(engine) orelse return;
    if (track < 0) return;
    _ = eng.queueAllNotesOff(@intCast(track));
}

/// Get parameter count for track instrument
export fn audio_engine_get_track_instrument_param_count(engine: ?*anyopaque, track: c_int) callconv(.c) c_int {
    if (castEngineConst(engine)) |eng| {
        if (eng.tracks[@intCast(track)].getInstrument()) |inst| {
            return @intCast(inst.getParameterCount());
        }
    }
    return 0;
}

/// Get instrument parameter name
export fn audio_engine_get_track_instrument_param_name(engine: ?*anyopaque, track: c_int, param: c_int) callconv(.c) [*:0]const u8 {
    if (castEngineConst(engine)) |eng| {
        if (eng.tracks[@intCast(track)].getInstrument()) |inst| {
            if (inst.getParameter(@intCast(param))) |p| {
                return @ptrCast(p.name.ptr);
            }
        }
    }
    return "Unknown";
}

/// Get instrument parameter value
export fn audio_engine_get_track_instrument_param_value(engine: ?*anyopaque, track: c_int, param: c_int) callconv(.c) f32 {
    if (castEngineConst(engine)) |eng| {
        if (eng.tracks[@intCast(track)].getInstrument()) |inst| {
            if (inst.getParameter(@intCast(param))) |p| {
                return p.value;
            }
        }
    }
    return 0.0;
}

/// Get instrument parameter min
export fn audio_engine_get_track_instrument_param_min(engine: ?*anyopaque, track: c_int, param: c_int) callconv(.c) f32 {
    if (castEngineConst(engine)) |eng| {
        if (eng.tracks[@intCast(track)].getInstrument()) |inst| {
            if (inst.getParameter(@intCast(param))) |p| {
                return p.min;
            }
        }
    }
    return 0.0;
}

/// Get instrument parameter max
export fn audio_engine_get_track_instrument_param_max(engine: ?*anyopaque, track: c_int, param: c_int) callconv(.c) f32 {
    if (castEngineConst(engine)) |eng| {
        if (eng.tracks[@intCast(track)].getInstrument()) |inst| {
            if (inst.getParameter(@intCast(param))) |p| {
                return p.max;
            }
        }
    }
    return 1.0;
}

/// Get instrument parameter unit (e.g., "Hz", "s", "dB")
export fn audio_engine_get_track_instrument_param_unit(engine: ?*anyopaque, track: c_int, param: c_int) callconv(.c) [*:0]const u8 {
    if (castEngineConst(engine)) |eng| {
        if (eng.tracks[@intCast(track)].getInstrument()) |inst| {
            if (inst.getParameter(@intCast(param))) |p| {
                return @ptrCast(p.unit.ptr);
            }
        }
    }
    return "";
}

/// Set instrument parameter value
pub export fn audio_engine_set_track_instrument_param(engine: ?*anyopaque, track: c_int, param: c_int, value: f32) callconv(.c) void {
    if (castEngine(engine)) |eng| {
        if (eng.tracks[@intCast(track)].getInstrument()) |inst| {
            inst.setParameter(@intCast(param), value);
        }
    }
}

/// Load audio from a buffer into a track
pub export fn audio_engine_load_track_audio(
    engine: ?*anyopaque,
    track: c_int,
    samples: [*]const f32,
    sample_count: u64,
    num_channels: u8,
    sample_rate: u32,
) callconv(.c) c_int {
    if (castEngine(engine)) |eng| {
        if (track < 0 or track >= eng.tracks.len) return -1;
        const slice = samples[0..sample_count];
        const track_idx: usize = @intCast(track);

        // Resample if sample rate doesn't match engine rate
        const input_rate = sample_rate;
        const target_rate = eng.config.sample_rate;

        if (input_rate != target_rate) {
            const log = std.log.scoped(.audio_engine);
            log.info("Resampling audio during load: {}Hz -> {}Hz", .{ input_rate, target_rate });

            const input_frames = sample_count / num_channels;
            const output_frames = dsp.calculateOutputLength(input_frames, input_rate, target_rate);
            const output_count = output_frames * num_channels;

            // Allocate output buffer
            const output_buffer = eng.allocator.alloc(f32, output_count) catch return -1;
            defer eng.allocator.free(output_buffer);

            // Resample each channel
            for (0..num_channels) |ch| {
                // Deinterleave input
                const channel_input = eng.allocator.alloc(f32, input_frames) catch return -1;
                defer eng.allocator.free(channel_input);
                for (0..input_frames) |i| {
                    channel_input[i] = slice[i * num_channels + ch];
                }

                // Allocate output
                const channel_output = eng.allocator.alloc(f32, output_frames) catch return -1;
                defer eng.allocator.free(channel_output);

                // Resample this channel
                dsp.resampleLinearByRate(channel_input, channel_output, input_rate, target_rate);

                // Interleave into output buffer
                for (0..output_frames) |i| {
                    output_buffer[i * num_channels + ch] = channel_output[i];
                }
            }

            // Load resampled data
            eng.tracks[track_idx].loadFromBuffer(output_buffer, num_channels, target_rate) catch return -1;
            return 0;
        }

        // No resampling needed - load directly
        eng.tracks[track_idx].loadFromBuffer(slice, num_channels, sample_rate) catch return -1;
        return 0;
    }
    return -1;
}

/// Clear audio clip from a track
pub export fn audio_engine_clear_track_audio(engine: ?*anyopaque, track: c_int) callconv(.c) void {
    if (castEngine(engine)) |eng| {
        if (track < 0 or track >= eng.tracks.len) return;
        if (eng.tracks[@intCast(track)].clip) |*clip| {
            clip.deinit();
            eng.tracks[@intCast(track)].clip = null;
        }
    }
}

// =============================================================================
// MIDI Note Helpers
// =============================================================================

/// Check if note is a black key
pub export fn midi_is_black_key(note: c_int) callconv(.c) c_int {
    const note_in_octave: u8 = @intCast(@mod(note, 12));
    return switch (note_in_octave) {
        1, 3, 6, 8, 10 => 1, // C#, D#, F#, G#, A#
        else => 0,
    };
}

// =============================================================================
// Audio Health Monitoring (Crash Prevention Analytics)
// =============================================================================

/// Get count of NaN/Infinity values that were sanitized (would have crashed CoreAudio)
pub export fn audio_engine_get_nan_inf_count(engine: ?*anyopaque) callconv(.c) u64 {
    if (castEngineConst(engine)) |eng| {
        return eng.nan_inf_count.load(.monotonic);
    }
    return 0;
}

/// Get count of samples that were clipped to prevent extreme values
pub export fn audio_engine_get_clip_count(engine: ?*anyopaque) callconv(.c) u64 {
    if (castEngineConst(engine)) |eng| {
        return eng.clip_count.load(.monotonic);
    }
    return 0;
}

/// Reset all audio health counters
pub export fn audio_engine_reset_health_stats(engine: ?*anyopaque) callconv(.c) void {
    if (castEngine(engine)) |eng| {
        eng.resetAudioHealthStats();
    }
}

/// Log health stats if there have been issues (for debugging)
pub export fn audio_engine_log_health_stats(engine: ?*anyopaque) callconv(.c) void {
    if (castEngine(engine)) |eng| {
        eng.logHealthStatsIfNeeded();
    }
}

// =============================================================================
// Tempo Control
// =============================================================================

/// Set tempo in BPM (20-300)
pub export fn audio_engine_set_tempo(engine: ?*anyopaque, bpm: f32) callconv(.c) void {
    if (castEngine(engine)) |eng| {
        eng.setTempo(bpm);
    }
}

/// Get current tempo in BPM
pub export fn audio_engine_get_tempo(engine: ?*anyopaque) callconv(.c) f32 {
    if (castEngine(engine)) |eng| {
        return eng.getTempo();
    }
    return 120.0;
}

/// Get current playback position in samples
pub export fn audio_engine_get_position(engine: ?*anyopaque) callconv(.c) u64 {
    if (castEngine(engine)) |eng| {
        return eng.getPosition();
    }
    return 0;
}

/// Get the playback engine's configured sample rate.
pub export fn audio_engine_get_sample_rate(engine: ?*anyopaque) callconv(.c) u32 {
    if (castEngineConst(engine)) |eng| {
        return eng.config.sample_rate;
    }
    return 48000;
}

// =============================================================================
// Audio settings API (UI thread only)
// Return codes: 0 ok, -1 null engine/pointer, -2 value not allowed, -3 backend
// cannot honour it, -4 backend re-open failed (old settings kept), -5 recording.
// =============================================================================

/// Map a settings error to its C return code.
fn settingCode(err: SettingError) c_int {
    return switch (err) {
        error.InvalidValue => -2,
        error.Unsupported => -3,
        error.ReopenFailed => -4,
        error.Busy => -5,
    };
}

/// Copy `src` plus a NUL into `out`. Returns the length excluding NUL, -1 for a bad
/// buffer, or -2 when it does not fit (then `out[0]` is cleared).
fn copyNameOut(src: []const u8, out: ?[*]u8, len: usize) c_int {
    const dst = out orelse return -1;
    if (len == 0) return -1;
    if (src.len + 1 > len) {
        dst[0] = 0;
        return -2;
    }
    @memcpy(dst[0..src.len], src);
    dst[src.len] = 0;
    return @intCast(src.len);
}

/// Set the playback output device by name; "" is the system default.
pub export fn audio_engine_set_output_device(engine: ?*anyopaque, name: ?[*:0]const u8) callconv(.c) c_int {
    const eng = castEngine(engine) orelse return -1;
    const name_ptr = name orelse return -1;
    eng.setOutputDevice(std.mem.span(name_ptr)) catch |err| return settingCode(err);
    return 0;
}

/// Copy the output device name ("" for the default) into `out_buf`.
pub export fn audio_engine_get_output_device(engine: ?*anyopaque, out_buf: ?[*]u8, len: usize) callconv(.c) c_int {
    const eng = castEngineConst(engine) orelse return -1;
    return copyNameOut(eng.outputDeviceName(), out_buf, len);
}

/// Set the capture device by name; "" is the default source. Used by the next recording.
pub export fn audio_engine_set_input_device(engine: ?*anyopaque, name: ?[*:0]const u8) callconv(.c) c_int {
    const eng = castEngine(engine) orelse return -1;
    const name_ptr = name orelse return -1;
    eng.setInputDevice(std.mem.span(name_ptr)) catch |err| return settingCode(err);
    return 0;
}

/// Copy the input device name ("" for the default) into `out_buf`.
pub export fn audio_engine_get_input_device(engine: ?*anyopaque, out_buf: ?[*]u8, len: usize) callconv(.c) c_int {
    const eng = castEngineConst(engine) orelse return -1;
    return copyNameOut(eng.inputDeviceName(), out_buf, len);
}

/// Set the playback buffer size in frames; must be one of the detected sizes.
pub export fn audio_engine_set_buffer_size(engine: ?*anyopaque, frames: u32) callconv(.c) c_int {
    const eng = castEngine(engine) orelse return -1;
    eng.setBufferSize(frames) catch |err| return settingCode(err);
    return 0;
}

/// Get the playback buffer size in frames.
pub export fn audio_engine_get_buffer_size(engine: ?*anyopaque) callconv(.c) u32 {
    if (castEngineConst(engine)) |eng| {
        return eng.config.buffer_size;
    }
    return 0;
}

/// Set the playback sample rate; must be one of the detected rates. Rescales the position.
pub export fn audio_engine_set_sample_rate(engine: ?*anyopaque, rate: u32) callconv(.c) c_int {
    const eng = castEngine(engine) orelse return -1;
    eng.setSampleRate(rate) catch |err| return settingCode(err);
    return 0;
}

/// Copy the backend name (pulseaudio, pipewire, coreaudio, none) into `out_buf`.
pub export fn audio_engine_get_backend(engine: ?*anyopaque, out_buf: ?[*]u8, len: usize) callconv(.c) c_int {
    const eng = castEngineConst(engine) orelse return -1;
    return copyNameOut(eng.backendName(), out_buf, len);
}

/// Restart the engine on a backend preference: "auto", "pulse", "pipewire" or "none".
/// Returns 0, -2 for an unknown name, -4 if that backend could not be opened (the previous one keeps running).
pub export fn audio_engine_set_backend(engine: ?*anyopaque, name: ?[*:0]const u8) callconv(.c) c_int {
    const eng = castEngine(engine) orelse return -1;
    const name_ptr = name orelse return -1;
    eng.setBackend(std.mem.span(name_ptr)) catch |err| return settingCode(err);
    return 0;
}

/// Copy the backend preference the user chose ("auto", "pulse", "pipewire" or "none") into `out_buf`.
pub export fn audio_engine_get_backend_preference(engine: ?*anyopaque, out_buf: ?[*]u8, len: usize) callconv(.c) c_int {
    const eng = castEngineConst(engine) orelse return -1;
    return copyNameOut(eng.backendPreference(), out_buf, len);
}

/// Set playback position in samples
pub export fn audio_engine_set_position(engine: ?*anyopaque, position: u64) callconv(.c) void {
    if (castEngine(engine)) |eng| {
        eng.position.store(position, .monotonic);
        // Also reset track clip positions when seeking to start
        if (position == 0) {
            eng.resetTracks();
        }
    }
}

/// Applies a named EQ preset (drums, bass, pads, lead, harp) to a track's
/// ParametricEQ, adding the EQ to the chain when absent. Returns 0, -1 for a
/// bad engine, track or name, -2 when the chain is full.
pub export fn audio_engine_eq_preset(engine: ?*anyopaque, track: c_int, name: [*:0]const u8) callconv(.c) c_int {
    const eng = castEngine(engine) orelse return -1;
    if (track < 0) return -1;
    const chain = eng.getTrackEffects(@intCast(track)) orelse return -1;
    const preset = eq_presets.Preset.parse(std.mem.span(name)) orelse return -1;
    eq_presets.applyPreset(chain, preset) catch |err| switch (err) {
        error.ChainFull => return -2,
        else => return -1,
    };
    return 0;
}

/// Turns the master tilt (+0.5 dB high shelf at 8 kHz) on or off. Returns 0, -1 or -2 (chain full).
pub export fn audio_engine_eq_master_tilt(engine: ?*anyopaque, on: c_int) callconv(.c) c_int {
    const eng = castEngine(engine) orelse return -1;
    eq_presets.setMasterTilt(eng.getMasterEffects(), on != 0) catch |err| switch (err) {
        error.ChainFull => return -2,
        else => return -1,
    };
    return 0;
}

// =============================================================================
// Hardware MIDI input (ALSA sequencer). All take the engine first, like the rest
// of this API; call from the UI thread, never the audio thread.
// =============================================================================

/// Number of readable MIDI input ports (re-enumerated on each call). 0 if ALSA is unavailable.
pub export fn audio_engine_midi_input_count(engine: ?*anyopaque) callconv(.c) c_int {
    const eng = castEngine(engine) orelse return 0;
    const m = eng.midiInput() orelse return 0;
    return @intCast(m.count());
}

/// Copy the name of input `index` into `buf` (NUL-terminated, truncated to `buf_len`).
/// Returns the name length, or -1 for a bad index or arguments.
pub export fn audio_engine_midi_input_name(engine: ?*anyopaque, index: c_int, buf: ?[*]u8, buf_len: c_int) callconv(.c) c_int {
    const eng = castEngine(engine) orelse return -1;
    const out = buf orelse return -1;
    if (index < 0 or buf_len <= 0) return -1;
    const m = eng.midi_input orelse return -1;
    const n = m.copyName(@intCast(index), out[0..@intCast(buf_len)]) orelse return -1;
    return @intCast(n);
}

/// Subscribe (on != 0) or unsubscribe input `index`. Returns 0 on success, -1 on failure.
pub export fn audio_engine_midi_input_set_enabled(engine: ?*anyopaque, index: c_int, on: c_int) callconv(.c) c_int {
    const eng = castEngine(engine) orelse return -1;
    if (index < 0) return -1;
    const m = eng.midiInput() orelse return -1;
    return if (m.setEnabled(@intCast(index), on != 0)) 0 else -1;
}

/// Choose the track whose instrument plays hardware MIDI input. Returns 0, or -1 if out of range.
pub export fn audio_engine_midi_input_selected_track(engine: ?*anyopaque, track: c_int) callconv(.c) c_int {
    const eng = castEngine(engine) orelse return -1;
    if (track < 0 or track >= AudioEngine.TRACK_COUNT) return -1;
    eng.setMidiInputTrack(@intCast(track));
    return 0;
}
