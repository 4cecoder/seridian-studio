//! C API wrapper for effects chains
//! Allows C code (GTK UI) to call into Zig effects system

const std = @import("std");
const AudioEngine = @import("engine.zig").AudioEngine;
const effects = @import("../effects/effects.zig");
const EffectsChain = effects.EffectsChain;
const EffectType = effects.EffectType;
const Effect = effects.Effect;
const Parameter = effects.Parameter;

// Helper to cast engine pointer
inline fn castEngine(engine: ?*anyopaque) ?*AudioEngine {
    return if (engine) |eng|
        @ptrCast(@alignCast(eng))
    else
        null;
}

// Get effects chain for track (-1 = master)
fn getChain(engine: ?*anyopaque, track: c_int) ?*EffectsChain {
    const eng = castEngine(engine) orelse return null;
    if (track < 0) {
        return eng.getMasterEffects();
    }
    return eng.getTrackEffects(@intCast(track));
}

// ==========================================================================
// Effect Type Enumeration
// ==========================================================================

const effect_type_names = [_][*:0]const u8{
    "Gain",
    "Filter",
    "Delay",
    "Compressor",
    "Reverb",
    "Wavefolder",
    "Bitcrusher",
    "Saturator",
    "Moog Filter",
    "Formant",
    "TB-303",
    "Limiter",
    "Gate",
    "Transient",
    "Freeverb",
    "Plate Reverb",
    "Spring Reverb",
    "Stereo Width",
    "Stereo Enhancer",
    "Auto Pan",
    "Pitch Shifter",
    "Freeze",
    "Parametric EQ",
    "Pro EQ",
    "De-esser",
    "Vocal Rider",
    "Denoise",
    "Tape",
    "Vocal Tune",
    "Vocal Strip",
};

/// Get number of available effect types (excluding 'none')
export fn get_effect_type_count() callconv(.c) c_int {
    return @intCast(effect_type_names.len);
}

/// Get name of effect type by index
export fn get_effect_type_name(index: c_int) callconv(.c) [*:0]const u8 {
    if (index < 0 or index >= effect_type_names.len) {
        return "Unknown";
    }
    return effect_type_names[@intCast(index)];
}

/// Convert index to EffectType enum (index 0 = gain, 1 = filter, etc.)
fn indexToEffectType(index: c_int) ?EffectType {
    return switch (index) {
        0 => .gain,
        1 => .filter,
        2 => .delay,
        3 => .compressor,
        4 => .reverb,
        5 => .wavefolder,
        6 => .bitcrusher,
        7 => .saturator,
        8 => .moog_filter,
        9 => .formant_filter,
        10 => .tb303_filter,
        11 => .limiter,
        12 => .gate,
        13 => .transient,
        14 => .freeverb,
        15 => .plate_reverb,
        16 => .spring_reverb,
        17 => .stereo_width,
        18 => .stereo_enhancer,
        19 => .auto_pan,
        20 => .pitch_shifter,
        21 => .freeze,
        22 => .parametric_eq,
        23 => .pro_eq,
        24 => .de_esser,
        25 => .vocal_rider,
        26 => .denoise,
        27 => .tape,
        28 => .vocal_tune,
        29 => .vocal_strip,
        else => null,
    };
}

/// Convert EffectType to index
fn effectTypeToIndex(t: EffectType) c_int {
    return switch (t) {
        .none => -1,
        .gain => 0,
        .filter => 1,
        .delay => 2,
        .compressor => 3,
        .reverb => 4,
        .wavefolder => 5,
        .bitcrusher => 6,
        .saturator => 7,
        .moog_filter => 8,
        .formant_filter => 9,
        .tb303_filter => 10,
        .limiter => 11,
        .gate => 12,
        .transient => 13,
        .freeverb => 14,
        .plate_reverb => 15,
        .spring_reverb => 16,
        .stereo_width => 17,
        .stereo_enhancer => 18,
        .auto_pan => 19,
        .pitch_shifter => 20,
        .freeze => 21,
        .parametric_eq => 22,
        .pro_eq => 23,
        .de_esser => 24,
        .vocal_rider => 25,
        .denoise => 26,
        .tape => 27,
        .vocal_tune => 28,
        .vocal_strip => 29,
    };
}

// ==========================================================================
// Query Effects Chain
// ==========================================================================

/// Get number of effects in chain
/// track: 0-3 for tracks, -1 for master
export fn track_get_effect_count(engine: ?*anyopaque, track: c_int) callconv(.c) c_int {
    const chain = getChain(engine, track) orelse return 0;
    return @intCast(chain.count);
}

/// Get effect type at slot (returns index into effect_type_names, -1 for empty)
export fn track_get_effect_type(engine: ?*anyopaque, track: c_int, slot: c_int) callconv(.c) c_int {
    const chain = getChain(engine, track) orelse return -1;
    if (slot < 0 or slot >= @as(c_int, @intCast(chain.count))) return -1;
    return effectTypeToIndex(chain.slots[@intCast(slot)].effect_type);
}

/// Get effect name at slot
export fn track_get_effect_name(engine: ?*anyopaque, track: c_int, slot: c_int) callconv(.c) [*:0]const u8 {
    const chain = getChain(engine, track) orelse return "Empty";
    if (slot < 0 or slot >= @as(c_int, @intCast(chain.count))) return "Empty";

    const name = chain.slots[@intCast(slot)].getName();
    // Return static string (getName returns string literals)
    return @ptrCast(name.ptr);
}

/// Get effect bypass state at slot
export fn track_get_effect_bypassed(engine: ?*anyopaque, track: c_int, slot: c_int) callconv(.c) c_int {
    const chain = getChain(engine, track) orelse return 0;
    if (slot < 0 or slot >= @as(c_int, @intCast(chain.count))) return 0;

    const effect = chain.slots[@intCast(slot)].getEffect() orelse return 0;
    return if (effect.bypassed) 1 else 0;
}

// ==========================================================================
// Modify Effects Chain
// ==========================================================================

/// Add effect to chain, returns slot index or -1 on error
/// effect_type: 0=gain, 1=filter, 2=delay, 3=compressor, 4=reverb
export fn track_add_effect(engine: ?*anyopaque, track: c_int, effect_type: c_int) callconv(.c) c_int {
    const chain = getChain(engine, track) orelse return -1;
    const etype = indexToEffectType(effect_type) orelse return -1;

    const slot = chain.addEffect(etype) catch |err| {
        std.log.err("Failed to add effect: {}", .{err});
        return -1;
    };

    return @intCast(slot);
}

/// Remove effect at slot, returns 0 on success
export fn track_remove_effect(engine: ?*anyopaque, track: c_int, slot: c_int) callconv(.c) c_int {
    const chain = getChain(engine, track) orelse return -1;
    if (slot < 0 or slot >= @as(c_int, @intCast(chain.count))) return -1;

    chain.removeEffect(@intCast(slot));
    return 0;
}

/// Swap two effects in chain
export fn track_swap_effects(engine: ?*anyopaque, track: c_int, slot_a: c_int, slot_b: c_int) callconv(.c) c_int {
    const chain = getChain(engine, track) orelse return -1;
    if (slot_a < 0 or slot_a >= @as(c_int, @intCast(chain.count))) return -1;
    if (slot_b < 0 or slot_b >= @as(c_int, @intCast(chain.count))) return -1;

    chain.swapEffects(@intCast(slot_a), @intCast(slot_b));
    return 0;
}

/// Set effect bypass state
export fn track_set_effect_bypass(engine: ?*anyopaque, track: c_int, slot: c_int, bypassed: c_int) callconv(.c) void {
    const chain = getChain(engine, track) orelse return;
    if (slot < 0 or slot >= @as(c_int, @intCast(chain.count))) return;

    const effect = chain.slots[@intCast(slot)].getEffect() orelse return;
    effect.bypassed = bypassed != 0;
}

// ==========================================================================
// Effect Parameters
// ==========================================================================

/// Get parameter count for effect at slot
export fn effect_get_param_count(engine: ?*anyopaque, track: c_int, slot: c_int) callconv(.c) c_int {
    const chain = getChain(engine, track) orelse return 0;
    if (slot < 0 or slot >= @as(c_int, @intCast(chain.count))) return 0;

    const effect = chain.slots[@intCast(slot)].getEffectConst() orelse return 0;
    return @intCast(effect.getParameterCount());
}

/// Get parameter name
export fn effect_get_param_name(engine: ?*anyopaque, track: c_int, slot: c_int, param: c_int) callconv(.c) [*:0]const u8 {
    const chain = getChain(engine, track) orelse return "Unknown";
    if (slot < 0 or slot >= @as(c_int, @intCast(chain.count))) return "Unknown";

    const effect = chain.slots[@intCast(slot)].getEffectConst() orelse return "Unknown";
    const p = effect.getParameter(@intCast(param)) orelse return "Unknown";

    // Parameter names are string literals
    return @ptrCast(p.name.ptr);
}

/// Get parameter value
export fn effect_get_param_value(engine: ?*anyopaque, track: c_int, slot: c_int, param: c_int) callconv(.c) f32 {
    const chain = getChain(engine, track) orelse return 0.0;
    if (slot < 0 or slot >= @as(c_int, @intCast(chain.count))) return 0.0;

    const effect = chain.slots[@intCast(slot)].getEffectConst() orelse return 0.0;
    const p = effect.getParameter(@intCast(param)) orelse return 0.0;
    return p.value;
}

/// Get parameter minimum value
export fn effect_get_param_min(engine: ?*anyopaque, track: c_int, slot: c_int, param: c_int) callconv(.c) f32 {
    const chain = getChain(engine, track) orelse return 0.0;
    if (slot < 0 or slot >= @as(c_int, @intCast(chain.count))) return 0.0;

    const effect = chain.slots[@intCast(slot)].getEffectConst() orelse return 0.0;
    const p = effect.getParameter(@intCast(param)) orelse return 0.0;
    return p.min;
}

/// Get parameter maximum value
export fn effect_get_param_max(engine: ?*anyopaque, track: c_int, slot: c_int, param: c_int) callconv(.c) f32 {
    const chain = getChain(engine, track) orelse return 1.0;
    if (slot < 0 or slot >= @as(c_int, @intCast(chain.count))) return 1.0;

    const effect = chain.slots[@intCast(slot)].getEffectConst() orelse return 1.0;
    const p = effect.getParameter(@intCast(param)) orelse return 1.0;
    return p.max;
}

/// Get parameter unit string
export fn effect_get_param_unit(engine: ?*anyopaque, track: c_int, slot: c_int, param: c_int) callconv(.c) [*:0]const u8 {
    const chain = getChain(engine, track) orelse return "";
    if (slot < 0 or slot >= @as(c_int, @intCast(chain.count))) return "";

    const effect = chain.slots[@intCast(slot)].getEffectConst() orelse return "";
    const p = effect.getParameter(@intCast(param)) orelse return "";

    if (p.unit.len == 0) return "";
    return @ptrCast(p.unit.ptr);
}

/// Set parameter value
export fn effect_set_param_value(engine: ?*anyopaque, track: c_int, slot: c_int, param: c_int, value: f32) callconv(.c) void {
    const chain = getChain(engine, track) orelse return;
    if (slot < 0 or slot >= @as(c_int, @intCast(chain.count))) return;

    const effect = chain.slots[@intCast(slot)].getEffect() orelse return;
    effect.setParameter(@intCast(param), value);
}

// ==========================================================================
// Chain-level Operations
// ==========================================================================

/// Get chain bypass state
export fn track_get_effects_bypassed(engine: ?*anyopaque, track: c_int) callconv(.c) c_int {
    const chain = getChain(engine, track) orelse return 0;
    return if (chain.bypassed) 1 else 0;
}

/// Set chain bypass state
export fn track_set_effects_bypassed(engine: ?*anyopaque, track: c_int, bypassed: c_int) callconv(.c) void {
    const chain = getChain(engine, track) orelse return;
    chain.bypassed = bypassed != 0;
}

/// Clear all effects from chain
export fn track_clear_effects(engine: ?*anyopaque, track: c_int) callconv(.c) void {
    const chain = getChain(engine, track) orelse return;
    chain.clear();
}
