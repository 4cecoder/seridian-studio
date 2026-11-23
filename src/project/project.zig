//! Project Session Management
//!
//! Stores all state needed to save and restore a DAW session:
//! - Project metadata (name, tempo, time signature)
//! - Track states (volume, pan, mute, solo, arm)
//! - Clip references (audio file paths, positions)
//! - Effects chain state per track + master
//!
//! Uses folder-based structure:
//!   /MyProject/
//!     project.daw     <- Binary/INI state
//!     /Audio/         <- Audio files

const std = @import("std");
const effects = @import("../effects/effects.zig");

const log = std.log.scoped(.project);

/// Maximum tracks (matches engine)
pub const TRACK_COUNT = 8;

/// Maximum effects per chain
pub const MAX_EFFECTS = 8;

/// Maximum clips per track
pub const MAX_CLIPS = 64;

/// Fixed-size name buffer
pub const NAME_LEN = 64;

/// Project file magic bytes: "ZDAW"
pub const MAGIC: u32 = 0x5741445A; // "ZDAW" in little-endian

/// Current file format version
pub const VERSION: u32 = 1;

// =============================================================================
// Effect State (for serialization)
// =============================================================================

/// Serializable effect slot
pub const EffectState = struct {
    /// Effect type (from EffectType enum)
    effect_type: u8 = 0, // 0 = none

    /// Bypassed state
    bypassed: bool = false,

    /// Parameter values (up to 16 params per effect)
    params: [16]f32 = @as([16]f32, @splat(0.0)),
    param_count: u8 = 0,

    pub fn fromEffectSlot(slot: *const effects.EffectSlot) EffectState {
        var state = EffectState{
            .effect_type = @backingInt(slot.effect_type),
        };

        if (slot.getEffectConst()) |effect| {
            state.bypassed = effect.bypassed;
            state.param_count = @intCast(effect.getParameterCount());

            var i: usize = 0;
            while (i < state.param_count and i < 16) : (i += 1) {
                if (effect.getParameter(i)) |p| {
                    state.params[i] = p.value;
                }
            }
        }

        return state;
    }
};

/// Effects chain state (matches chain.zig MAX_EFFECTS = 8)
pub const EffectsChainState = struct {
    effects: [MAX_EFFECTS]EffectState = @as([MAX_EFFECTS]EffectState, @splat(.{})),
    count: u8 = 0,
    bypassed: bool = false,

    pub fn fromChain(chain: *const effects.EffectsChain) EffectsChainState {
        var state = EffectsChainState{
            .count = @intCast(chain.count),
            .bypassed = chain.bypassed,
        };

        for (0..chain.count) |i| {
            state.effects[i] = EffectState.fromEffectSlot(&chain.slots[i]);
        }

        return state;
    }
};

// =============================================================================
// Clip State (for serialization)
// =============================================================================

/// Serializable clip reference
pub const ClipState = struct {
    /// Display name
    name: [NAME_LEN]u8 = std.mem.zeroes([NAME_LEN]u8),

    /// Audio file path (relative to project folder)
    file_path: [256]u8 = std.mem.zeroes([256]u8),

    /// Visual color (RGB hex)
    color: u32 = 0x7aa2f7,

    /// Timeline position (seconds)
    start_time: f64 = 0.0,

    /// Duration (seconds)
    duration: f64 = 1.0,

    /// Offset within source (for trimmed clips)
    source_offset: f64 = 0.0,

    /// Volume adjustment
    gain: f32 = 1.0,

    /// Muted state
    muted: bool = false,

    pub fn setName(self: *ClipState, name: []const u8) void {
        const len = @min(name.len, NAME_LEN - 1);
        @memcpy(self.name[0..len], name[0..len]);
        self.name[len] = 0;
    }

    pub fn getName(self: *const ClipState) []const u8 {
        var len: usize = 0;
        while (len < NAME_LEN and self.name[len] != 0) : (len += 1) {}
        return self.name[0..len];
    }

    pub fn setFilePath(self: *ClipState, path: []const u8) void {
        const len = @min(path.len, 255);
        @memcpy(self.file_path[0..len], path[0..len]);
        self.file_path[len] = 0;
    }

    pub fn getFilePath(self: *const ClipState) []const u8 {
        var len: usize = 0;
        while (len < 256 and self.file_path[len] != 0) : (len += 1) {}
        return self.file_path[0..len];
    }
};

// =============================================================================
// Track State
// =============================================================================

/// Serializable track state
pub const TrackState = struct {
    /// Track name
    name: [NAME_LEN]u8 = std.mem.zeroes([NAME_LEN]u8),

    /// Volume (0.0 to 1.0)
    volume: f32 = 0.75,

    /// Pan (-1.0 left to 1.0 right)
    pan: f32 = 0.0,

    /// Muted state
    muted: bool = false,

    /// Solo state
    solo: bool = false,

    /// Record armed
    armed: bool = false,

    /// Instrument type (0 = none, 1+ = instrument index)
    instrument_type: u8 = 0,

    /// Capture input (0 = none, n = capture device index + 1)
    input_device: u8 = 0,

    /// Effects chain
    effects_chain: EffectsChainState = .{},

    /// Clips on this track
    clips: [MAX_CLIPS]ClipState = @as([MAX_CLIPS]ClipState, @splat(.{})),
    clip_count: u8 = 0,

    pub fn setName(self: *TrackState, name: []const u8) void {
        const len = @min(name.len, NAME_LEN - 1);
        @memcpy(self.name[0..len], name[0..len]);
        self.name[len] = 0;
    }

    pub fn getName(self: *const TrackState) []const u8 {
        var len: usize = 0;
        while (len < NAME_LEN and self.name[len] != 0) : (len += 1) {}
        return self.name[0..len];
    }

    pub fn default(index: usize) TrackState {
        var state = TrackState{};
        var name_buf: [16]u8 = undefined;
        const name = std.fmt.bufPrint(&name_buf, "Track {d}", .{index + 1}) catch "Track";
        state.setName(name);
        return state;
    }
};

// =============================================================================
// Project Header
// =============================================================================

/// Main project header
pub const ProjectHeader = struct {
    /// Magic bytes for validation
    magic: u32 = MAGIC,

    /// File format version
    version: u32 = VERSION,

    /// Project name
    name: [NAME_LEN]u8 = std.mem.zeroes([NAME_LEN]u8),

    /// Tempo (BPM)
    bpm: f32 = 120.0,

    /// Time signature numerator
    time_sig_num: u8 = 4,

    /// Time signature denominator
    time_sig_den: u8 = 4,

    /// Sample rate
    sample_rate: u32 = 48000,

    /// Master volume
    master_volume: f32 = 0.75,

    /// Loop start position (seconds)
    loop_start: f64 = 0.0,

    /// Loop end position (seconds)
    loop_end: f64 = 0.0,

    /// Loop enabled
    loop_enabled: bool = false,

    /// Reserved for future use (keeps struct stable for version 1)
    _reserved: [64]u8 = std.mem.zeroes([64]u8),

    pub fn setName(self: *ProjectHeader, name: []const u8) void {
        const len = @min(name.len, NAME_LEN - 1);
        @memcpy(self.name[0..len], name[0..len]);
        self.name[len] = 0;
    }

    pub fn getName(self: *const ProjectHeader) []const u8 {
        var len: usize = 0;
        while (len < NAME_LEN and self.name[len] != 0) : (len += 1) {}
        return self.name[0..len];
    }

    pub fn validate(self: *const ProjectHeader) bool {
        return self.magic == MAGIC and self.version <= VERSION;
    }
};

// =============================================================================
// Full Project State
// =============================================================================

/// Complete project state for save/load
pub const Project = struct {
    /// Project header (metadata)
    header: ProjectHeader = .{},

    /// Track states (TRACK_COUNT tracks)
    tracks: [TRACK_COUNT]TrackState = undefined,

    /// Master effects chain
    master_effects: EffectsChainState = .{},

    /// Project folder path (runtime only, not saved)
    folder_path: ?[]const u8 = null,

    /// Has unsaved changes
    dirty: bool = false,

    pub fn init() Project {
        var project = Project{};

        // Initialize tracks with default names
        for (0..TRACK_COUNT) |i| {
            project.tracks[i] = TrackState.default(i);
        }

        project.header.setName("Untitled");
        return project;
    }

    /// Mark project as modified
    pub fn markDirty(self: *Project) void {
        self.dirty = true;
    }

    /// Clear dirty flag (after save)
    pub fn clearDirty(self: *Project) void {
        self.dirty = false;
    }

    /// Check if project has a save location
    pub fn hasSaveLocation(self: *const Project) bool {
        return self.folder_path != null;
    }
};

// =============================================================================
// Tests
// =============================================================================

test "project header validation" {
    const testing = std.testing;

    var header = ProjectHeader{};
    try testing.expect(header.validate());

    header.magic = 0xDEADBEEF;
    try testing.expect(!header.validate());
}

test "track state default" {
    const testing = std.testing;

    const track = TrackState.default(0);
    try testing.expectEqualStrings("Track 1", track.getName());
    try testing.expectEqual(@as(f32, 0.75), track.volume);
    try testing.expect(!track.muted);
}

test "project init" {
    const testing = std.testing;

    const project = Project.init();
    try testing.expectEqualStrings("Untitled", project.header.getName());
    try testing.expectEqualStrings("Track 1", project.tracks[0].getName());
    try testing.expectEqualStrings("Track 4", project.tracks[3].getName());
}

test "clip state name" {
    const testing = std.testing;

    var clip = ClipState{};
    clip.setName("My Audio Clip");
    try testing.expectEqualStrings("My Audio Clip", clip.getName());

    clip.setFilePath("Audio/recording_001.wav");
    try testing.expectEqualStrings("Audio/recording_001.wav", clip.getFilePath());
}
