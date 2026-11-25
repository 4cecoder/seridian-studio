//! Project Persistence Layer
//!
//! Handles save/load of project sessions using folder-based structure:
//!   /MyProject/
//!     project.daw      <- INI-based state file
//!     /Audio/          <- Audio files (WAV)
//!     /Backups/        <- Auto-save backups
//!
//! Uses atomic save (write to temp, then rename) to prevent corruption.

const std = @import("std");
const sys = @import("../utils/sys.zig");
const project_mod = @import("project.zig");
const Project = project_mod.Project;
const ProjectHeader = project_mod.ProjectHeader;
const TrackState = project_mod.TrackState;
const EffectsChainState = project_mod.EffectsChainState;
const EffectState = project_mod.EffectState;
const ClipState = project_mod.ClipState;
const xdg = @import("../config/xdg.zig");

const log = std.log.scoped(.project_persistence);

// MIDI clip C API for serialization
extern fn midi_clip_get_serialize_size(track: c_int) callconv(.c) c_int;
extern fn midi_clip_serialize(track: c_int, out_buffer: [*]u8, buffer_size: c_int) callconv(.c) c_int;
extern fn midi_clip_deserialize(track: c_int, in_buffer: [*]const u8, buffer_size: c_int) callconv(.c) c_int;
extern fn midi_clip_has_notes(track: c_int) callconv(.c) c_int;
extern fn midi_clip_clear(track: c_int) callconv(.c) void;
extern fn midi_clip_add_note(track: c_int, start_beat: f64, duration: f64, pitch: u8, velocity: u8) callconv(.c) u32;
extern fn midi_clip_get_note_count(track: c_int) callconv(.c) c_int;

/// Project file name
const PROJECT_FILE = "project.daw";
const TEMP_FILE = "project.daw.tmp";
const MIDI_FILE_PREFIX = "midi_track";
const MIDI_FILE_EXT = ".bin";
/// Attempts to serialize a clip that is being edited while it is saved.
/// Upper bound on one track file when loading (guards against absurd allocations).
const MAX_MIDI_FILE_BYTES = 256 * 1024 * 1024;
const MIDI_SERIALIZE_RETRIES = 4;

/// Fixed buffer writer for INI generation
const FixedBufferWriter = struct {
    buf: []u8,
    pos: usize = 0,

    fn writeAll(self: *FixedBufferWriter, data: []const u8) !void {
        if (self.pos + data.len > self.buf.len) return error.NoSpaceLeft;
        @memcpy(self.buf[self.pos..][0..data.len], data);
        self.pos += data.len;
    }

    fn print(self: *FixedBufferWriter, comptime fmt: []const u8, args: anytype) !void {
        const written = std.fmt.bufPrint(self.buf[self.pos..], fmt, args) catch return error.NoSpaceLeft;
        self.pos += written.len;
    }

    fn getWritten(self: *const FixedBufferWriter) []const u8 {
        return self.buf[0..self.pos];
    }
};

// =============================================================================
// Project Folder Management
// =============================================================================

/// Get default projects directory (XDG data dir)
pub fn getProjectsDir(allocator: std.mem.Allocator) ![]const u8 {
    const data_dir = try xdg.getDataDir(allocator);
    defer allocator.free(data_dir);

    return try std.fs.path.join(allocator, &[_][]const u8{ data_dir, "daw", "projects" });
}

/// Create a new project folder
pub fn createProjectFolder(allocator: std.mem.Allocator, base_path: []const u8, name: []const u8) ![]const u8 {
    // Build full path
    const folder_path = try std.fs.path.join(allocator, &[_][]const u8{ base_path, name });
    errdefer allocator.free(folder_path);

    // Create directories
    try sys.makePath(folder_path);

    const audio_path = try std.fs.path.join(allocator, &[_][]const u8{ folder_path, "Audio" });
    defer allocator.free(audio_path);
    try sys.makePath(audio_path);

    const backups_path = try std.fs.path.join(allocator, &[_][]const u8{ folder_path, "Backups" });
    defer allocator.free(backups_path);
    try sys.makePath(backups_path);

    log.info("Created project folder: {s}", .{folder_path});
    return folder_path;
}

// =============================================================================
// Save Project
// =============================================================================

/// Save project to its folder (atomic write)
pub fn saveProject(allocator: std.mem.Allocator, project: *const Project, folder_path: []const u8) !void {
    // Generate INI content
    var content_buf: [65536]u8 = undefined; // 64KB should be plenty
    var writer = FixedBufferWriter{ .buf = &content_buf };

    try writeProjectIni(&writer, project);

    // Atomic save: write to temp file first
    const temp_path = try std.fs.path.join(allocator, &[_][]const u8{ folder_path, TEMP_FILE });
    defer allocator.free(temp_path);

    const final_path = try std.fs.path.join(allocator, &[_][]const u8{ folder_path, PROJECT_FILE });
    defer allocator.free(final_path);

    // Write temp file
    const file = try std.Io.Dir.cwd().createFile(sys.io(), temp_path, .{});
    defer file.close(sys.io());
    try file.writeStreamingAll(sys.io(), writer.getWritten());

    // Atomic rename
    try std.Io.Dir.cwd().rename(temp_path, std.Io.Dir.cwd(), final_path, sys.io());

    // Save MIDI data for each track
    try saveMidiData(allocator, folder_path);

    log.info("Project saved: {s}", .{final_path});
}

/// Save MIDI data for all tracks. Each buffer is sized from the clip, so no
/// track is dropped; any track that cannot be written is an error.
fn saveMidiData(allocator: std.mem.Allocator, folder_path: []const u8) !void {
    for (0..project_mod.TRACK_COUNT) |track_idx| {
        const track: c_int = @intCast(track_idx);

        var filename_buf: [64]u8 = undefined;
        const filename = try std.fmt.bufPrint(&filename_buf, "{s}{d}{s}", .{
            MIDI_FILE_PREFIX,
            track_idx,
            MIDI_FILE_EXT,
        });
        const midi_path = try std.fs.path.join(allocator, &[_][]const u8{ folder_path, filename });
        defer allocator.free(midi_path);

        // Tracks with no MIDI data: delete a stale file from an earlier save.
        if (midi_clip_has_notes(track) == 0) {
            std.Io.Dir.cwd().deleteFile(sys.io(), midi_path) catch |err| switch (err) {
                error.FileNotFound => {},
                else => {
                    log.warn("Failed to remove stale MIDI file {s}: {}", .{ midi_path, err });
                    return err;
                },
            };
            continue;
        }

        // Serialize into a buffer sized for this clip. The clip can grow
        // between the size query and the copy, so retry on a too-small buffer.
        var buffer: []u8 = &.{};
        defer allocator.free(buffer);
        var written: usize = 0;
        var attempts: usize = 0;
        while (attempts < MIDI_SERIALIZE_RETRIES) : (attempts += 1) {
            const needed = midi_clip_get_serialize_size(track);
            if (needed <= 0) return error.MidiSerializeFailed;
            allocator.free(buffer);
            buffer = &.{};
            buffer = try allocator.alloc(u8, @intCast(needed));
            const size = midi_clip_serialize(track, buffer.ptr, @intCast(buffer.len));
            if (size > 0) {
                written = @intCast(size);
                break;
            }
        }
        if (written == 0) return error.MidiSerializeFailed;
        const data = buffer[0..written];

        const midi_file = std.Io.Dir.cwd().createFile(sys.io(), midi_path, .{}) catch |err| {
            log.warn("Failed to create MIDI file {s}: {}", .{ midi_path, err });
            return err;
        };
        defer midi_file.close(sys.io());

        midi_file.writeStreamingAll(sys.io(), data) catch |err| {
            log.warn("Failed to write MIDI file {s}: {}", .{ midi_path, err });
            return err;
        };

        log.info("Saved MIDI data for track {}: {s} ({} bytes)", .{ track_idx, midi_path, data.len });
    }
}

/// Write project to INI format
fn writeProjectIni(writer: *FixedBufferWriter, project: *const Project) !void {
    try writer.writeAll("# DAW Project File\n");
    try writer.writeAll("# Auto-generated - do not edit manually\n\n");

    // Project header
    try writer.writeAll("[Project]\n");
    try writer.print("name = {s}\n", .{project.header.getName()});
    try writer.print("bpm = {d:.2}\n", .{project.header.bpm});
    try writer.print("time_sig_num = {d}\n", .{project.header.time_sig_num});
    try writer.print("time_sig_den = {d}\n", .{project.header.time_sig_den});
    try writer.print("sample_rate = {d}\n", .{project.header.sample_rate});
    try writer.print("master_volume = {d:.4}\n", .{project.header.master_volume});
    try writer.print("loop_start = {d:.6}\n", .{project.header.loop_start});
    try writer.print("loop_end = {d:.6}\n", .{project.header.loop_end});
    try writer.print("loop_enabled = {}\n\n", .{project.header.loop_enabled});

    // Master effects
    try writeEffectsChain(writer, "MasterEffects", &project.master_effects);

    // Tracks
    for (0..project_mod.TRACK_COUNT) |i| {
        try writeTrack(writer, i, &project.tracks[i]);
    }
}

fn writeTrack(writer: *FixedBufferWriter, index: usize, track: *const TrackState) !void {
    try writer.print("[Track{d}]\n", .{index});
    try writer.print("name = {s}\n", .{track.getName()});
    try writer.print("volume = {d:.4}\n", .{track.volume});
    try writer.print("pan = {d:.4}\n", .{track.pan});
    try writer.print("muted = {}\n", .{track.muted});
    try writer.print("solo = {}\n", .{track.solo});
    try writer.print("armed = {}\n", .{track.armed});
    try writer.print("instrument_type = {d}\n", .{track.instrument_type});
    try writer.print("input_device = {d}\n", .{track.input_device});
    try writer.print("clip_count = {d}\n\n", .{track.clip_count});

    // Track effects
    var section_name: [32]u8 = undefined;
    const section = std.fmt.bufPrint(&section_name, "Track{d}Effects", .{index}) catch "TrackEffects";
    try writeEffectsChain(writer, section, &track.effects_chain);

    // Track clips
    for (0..track.clip_count) |ci| {
        try writeClip(writer, index, ci, &track.clips[ci]);
    }
}

fn writeEffectsChain(writer: *FixedBufferWriter, section: []const u8, chain: *const EffectsChainState) !void {
    try writer.print("[{s}]\n", .{section});
    try writer.print("count = {d}\n", .{chain.count});
    try writer.print("bypassed = {}\n", .{chain.bypassed});

    for (0..chain.count) |i| {
        const effect = &chain.effects[i];
        try writer.print("effect{d}_type = {d}\n", .{ i, effect.effect_type });
        try writer.print("effect{d}_bypassed = {}\n", .{ i, effect.bypassed });
        try writer.print("effect{d}_param_count = {d}\n", .{ i, effect.param_count });

        for (0..effect.param_count) |pi| {
            try writer.print("effect{d}_param_{d} = {d:.6}\n", .{ i, pi, effect.params[pi] });
        }
    }
    try writer.writeAll("\n");
}

fn writeClip(writer: *FixedBufferWriter, track_idx: usize, clip_idx: usize, clip: *const ClipState) !void {
    try writer.print("[Track{d}Clip{d}]\n", .{ track_idx, clip_idx });
    try writer.print("name = {s}\n", .{clip.getName()});
    try writer.print("file_path = {s}\n", .{clip.getFilePath()});
    try writer.print("color = {d}\n", .{clip.color});
    try writer.print("start_time = {d:.6}\n", .{clip.start_time});
    try writer.print("duration = {d:.6}\n", .{clip.duration});
    try writer.print("source_offset = {d:.6}\n", .{clip.source_offset});
    try writer.print("gain = {d:.4}\n", .{clip.gain});
    try writer.print("muted = {}\n\n", .{clip.muted});
}

// =============================================================================
// Load Project
// =============================================================================

/// Load project from folder
pub fn loadProject(allocator: std.mem.Allocator, folder_path: []const u8) !Project {
    const file_path = try std.fs.path.join(allocator, &[_][]const u8{ folder_path, PROJECT_FILE });
    defer allocator.free(file_path);

    const file = std.Io.Dir.cwd().openFile(sys.io(), file_path, .{}) catch |err| {
        if (err == error.FileNotFound) {
            log.warn("Project file not found: {s}", .{file_path});
            return error.ProjectNotFound;
        }
        return err;
    };
    defer file.close(sys.io());

    // Read file
    const stat = try file.stat(sys.io());
    const file_size = @min(stat.size, 65536);

    var content_buf: [65536]u8 = undefined;
    const bytes_read = try file.readPositionalAll(sys.io(), &content_buf, 0);
    const content = content_buf[0..@min(bytes_read, file_size)];

    // Parse INI
    var project = Project.init();
    try parseProjectIni(&project, content);

    // Load MIDI data for each track
    loadMidiData(allocator, folder_path) catch |err| {
        log.warn("Failed to load MIDI data: {}", .{err});
    };

    log.info("Project loaded: {s}", .{file_path});
    return project;
}

/// Load MIDI data for all tracks
fn loadMidiData(allocator: std.mem.Allocator, folder_path: []const u8) !void {
    for (0..project_mod.TRACK_COUNT) |track_idx| {
        const track: c_int = @intCast(track_idx);

        // Clear existing MIDI data first
        midi_clip_clear(track);

        // Build filename: midi_track0.bin, midi_track1.bin, etc.
        var filename_buf: [64]u8 = undefined;
        const filename = std.fmt.bufPrint(&filename_buf, "{s}{d}{s}", .{
            MIDI_FILE_PREFIX,
            track_idx,
            MIDI_FILE_EXT,
        }) catch continue;

        const midi_path = std.fs.path.join(allocator, &[_][]const u8{ folder_path, filename }) catch continue;
        defer allocator.free(midi_path);

        // Try to open MIDI file
        const midi_file = std.Io.Dir.cwd().openFile(sys.io(), midi_path, .{}) catch |err| {
            if (err != error.FileNotFound) {
                log.warn("Failed to open MIDI file {s}: {}", .{ midi_path, err });
            }
            continue;
        };
        defer midi_file.close(sys.io());

        // Read MIDI file: the buffer is sized from the file, so no clip is cut.
        const stat = midi_file.stat(sys.io()) catch continue;
        if (stat.size == 0 or stat.size > MAX_MIDI_FILE_BYTES) {
            if (stat.size != 0) log.warn("MIDI file {s} is too large ({} bytes)", .{ midi_path, stat.size });
            continue;
        }
        const midi_buffer = allocator.alloc(u8, @intCast(stat.size)) catch |err| {
            log.warn("Failed to allocate MIDI buffer for {s}: {}", .{ midi_path, err });
            continue;
        };
        defer allocator.free(midi_buffer);

        const bytes_read = midi_file.readPositionalAll(sys.io(), midi_buffer, 0) catch |err| {
            log.warn("Failed to read MIDI file {s}: {}", .{ midi_path, err });
            continue;
        };

        if (bytes_read == 0) continue;

        // Deserialize MIDI data
        const note_count = midi_clip_deserialize(track, midi_buffer.ptr, @intCast(bytes_read));
        if (note_count > 0) {
            log.info("Loaded {} MIDI notes for track {} from {s}", .{ note_count, track_idx, midi_path });
        }
    }
}

/// Parse project INI content
fn parseProjectIni(project: *Project, content: []const u8) !void {
    var lines = std.mem.splitScalar(u8, content, '\n');
    var current_section: ?[]const u8 = null;

    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");

        // Skip empty lines and comments
        if (trimmed.len == 0 or trimmed[0] == '#') continue;

        // Section header
        if (trimmed[0] == '[' and trimmed[trimmed.len - 1] == ']') {
            current_section = trimmed[1 .. trimmed.len - 1];
            continue;
        }

        // Key-value pair
        var kv = std.mem.splitScalar(u8, trimmed, '=');
        const key = std.mem.trim(u8, kv.next() orelse continue, " \t");
        const value = std.mem.trim(u8, kv.rest(), " \t");

        if (current_section) |section| {
            parseKeyValue(project, section, key, value) catch |err| {
                log.warn("Failed to parse {s}.{s}: {}", .{ section, key, err });
            };
        }
    }
}

fn parseKeyValue(project: *Project, section: []const u8, key: []const u8, value: []const u8) !void {
    // Project section
    if (std.mem.eql(u8, section, "Project")) {
        if (std.mem.eql(u8, key, "name")) {
            project.header.setName(value);
        } else if (std.mem.eql(u8, key, "bpm")) {
            project.header.bpm = try std.fmt.parseFloat(f32, value);
        } else if (std.mem.eql(u8, key, "time_sig_num")) {
            project.header.time_sig_num = try std.fmt.parseInt(u8, value, 10);
        } else if (std.mem.eql(u8, key, "time_sig_den")) {
            project.header.time_sig_den = try std.fmt.parseInt(u8, value, 10);
        } else if (std.mem.eql(u8, key, "sample_rate")) {
            project.header.sample_rate = try std.fmt.parseInt(u32, value, 10);
        } else if (std.mem.eql(u8, key, "master_volume")) {
            project.header.master_volume = try std.fmt.parseFloat(f32, value);
        } else if (std.mem.eql(u8, key, "loop_start")) {
            project.header.loop_start = try std.fmt.parseFloat(f64, value);
        } else if (std.mem.eql(u8, key, "loop_end")) {
            project.header.loop_end = try std.fmt.parseFloat(f64, value);
        } else if (std.mem.eql(u8, key, "loop_enabled")) {
            project.header.loop_enabled = std.mem.eql(u8, value, "true");
        }
        return;
    }

    // Track sections (Track0, Track1, etc.)
    if (std.mem.startsWith(u8, section, "Track") and !std.mem.endsWith(u8, section, "Effects") and !std.mem.containsAtLeast(u8, section, 1, "Clip")) {
        const track_idx = std.fmt.parseInt(usize, section[5..], 10) catch return;
        if (track_idx >= project_mod.TRACK_COUNT) return;

        const track = &project.tracks[track_idx];
        if (std.mem.eql(u8, key, "name")) {
            track.setName(value);
        } else if (std.mem.eql(u8, key, "volume")) {
            track.volume = try std.fmt.parseFloat(f32, value);
        } else if (std.mem.eql(u8, key, "pan")) {
            track.pan = try std.fmt.parseFloat(f32, value);
        } else if (std.mem.eql(u8, key, "muted")) {
            track.muted = std.mem.eql(u8, value, "true");
        } else if (std.mem.eql(u8, key, "solo")) {
            track.solo = std.mem.eql(u8, value, "true");
        } else if (std.mem.eql(u8, key, "armed")) {
            track.armed = std.mem.eql(u8, value, "true");
        } else if (std.mem.eql(u8, key, "instrument_type")) {
            track.instrument_type = try std.fmt.parseInt(u8, value, 10);
        } else if (std.mem.eql(u8, key, "input_device")) {
            track.input_device = try std.fmt.parseInt(u8, value, 10);
        } else if (std.mem.eql(u8, key, "clip_count")) {
            track.clip_count = try std.fmt.parseInt(u8, value, 10);
        }
        return;
    }

    // Effects chain sections
    if (std.mem.endsWith(u8, section, "Effects")) {
        const chain = if (std.mem.eql(u8, section, "MasterEffects"))
            &project.master_effects
        else blk: {
            // Track effects: "Track0Effects" -> 0
            const prefix = "Track";
            const suffix = "Effects";
            if (section.len > prefix.len + suffix.len) {
                const idx_str = section[prefix.len .. section.len - suffix.len];
                const idx = std.fmt.parseInt(usize, idx_str, 10) catch return;
                if (idx < project_mod.TRACK_COUNT) {
                    break :blk &project.tracks[idx].effects_chain;
                }
            }
            return;
        };

        if (std.mem.eql(u8, key, "count")) {
            chain.count = try std.fmt.parseInt(u8, value, 10);
        } else if (std.mem.eql(u8, key, "bypassed")) {
            chain.bypassed = std.mem.eql(u8, value, "true");
        } else if (std.mem.startsWith(u8, key, "effect")) {
            // Parse effect parameters: effect0_type, effect0_bypassed, effect0_param0, etc.
            try parseEffectParam(chain, key[6..], value);
        }
        return;
    }

    // Clip sections: Track0Clip0, Track0Clip1, etc.
    if (std.mem.startsWith(u8, section, "Track") and std.mem.containsAtLeast(u8, section, 1, "Clip")) {
        // Parse "Track0Clip1" -> track=0, clip=1
        var parts = std.mem.splitSequence(u8, section, "Clip");
        const track_part = parts.next() orelse return;
        const clip_idx_str = parts.next() orelse return;

        if (track_part.len <= 5) return;
        const track_idx = std.fmt.parseInt(usize, track_part[5..], 10) catch return;
        const clip_idx = std.fmt.parseInt(usize, clip_idx_str, 10) catch return;

        if (track_idx >= project_mod.TRACK_COUNT) return;
        if (clip_idx >= project_mod.MAX_CLIPS) return;

        const clip = &project.tracks[track_idx].clips[clip_idx];
        if (std.mem.eql(u8, key, "name")) {
            clip.setName(value);
        } else if (std.mem.eql(u8, key, "file_path")) {
            clip.setFilePath(value);
        } else if (std.mem.eql(u8, key, "color")) {
            clip.color = try std.fmt.parseInt(u32, value, 10);
        } else if (std.mem.eql(u8, key, "start_time")) {
            clip.start_time = try std.fmt.parseFloat(f64, value);
        } else if (std.mem.eql(u8, key, "duration")) {
            clip.duration = try std.fmt.parseFloat(f64, value);
        } else if (std.mem.eql(u8, key, "source_offset")) {
            clip.source_offset = try std.fmt.parseFloat(f64, value);
        } else if (std.mem.eql(u8, key, "gain")) {
            clip.gain = try std.fmt.parseFloat(f32, value);
        } else if (std.mem.eql(u8, key, "muted")) {
            clip.muted = std.mem.eql(u8, value, "true");
        }
    }
}

fn parseEffectParam(chain: *EffectsChainState, key_suffix: []const u8, value: []const u8) !void {
    // key_suffix examples: "0_type", "0_bypassed", "0_param_count", "0_param0"
    var parts = std.mem.splitScalar(u8, key_suffix, '_');
    const idx_str = parts.next() orelse return;
    const effect_idx = try std.fmt.parseInt(usize, idx_str, 10);
    if (effect_idx >= project_mod.MAX_EFFECTS) return;

    const effect = &chain.effects[effect_idx];
    const field = parts.next() orelse return;

    if (std.mem.eql(u8, field, "type")) {
        effect.effect_type = try std.fmt.parseInt(u8, value, 10);
    } else if (std.mem.eql(u8, field, "bypassed")) {
        effect.bypassed = std.mem.eql(u8, value, "true");
    } else if (std.mem.eql(u8, field, "param")) {
        // "param" followed by "count" or index
        const rest = parts.next() orelse return;
        if (std.mem.eql(u8, rest, "count")) {
            effect.param_count = try std.fmt.parseInt(u8, value, 10);
        } else {
            const param_idx = try std.fmt.parseInt(usize, rest, 10);
            if (param_idx < 16) {
                effect.params[param_idx] = try std.fmt.parseFloat(f32, value);
            }
        }
    }
}

// =============================================================================
// Tests
// =============================================================================

test "save and load project" {
    const testing = std.testing;
    _ = testing.allocator; // Available for future disk tests

    // Create a project with some state
    var project = Project.init();
    project.header.setName("Test Project");
    project.header.bpm = 140.0;
    project.header.master_volume = 0.8;

    project.tracks[0].setName("Drums");
    project.tracks[0].volume = 0.9;
    project.tracks[0].muted = true;

    project.tracks[1].setName("Bass");
    project.tracks[1].pan = -0.5;

    // Add a clip
    project.tracks[0].clips[0].setName("Kick Pattern");
    project.tracks[0].clips[0].start_time = 1.0;
    project.tracks[0].clips[0].duration = 4.0;
    project.tracks[0].clip_count = 1;

    // Generate INI
    var content_buf: [65536]u8 = undefined;
    var writer = FixedBufferWriter{ .buf = &content_buf };
    try writeProjectIni(&writer, &project);

    // Parse it back
    var loaded = Project.init();
    try parseProjectIni(&loaded, writer.getWritten());

    // Verify
    try testing.expectEqualStrings("Test Project", loaded.header.getName());
    try testing.expectApproxEqRel(@as(f32, 140.0), loaded.header.bpm, 0.01);
    try testing.expectApproxEqRel(@as(f32, 0.8), loaded.header.master_volume, 0.01);

    try testing.expectEqualStrings("Drums", loaded.tracks[0].getName());
    try testing.expectApproxEqRel(@as(f32, 0.9), loaded.tracks[0].volume, 0.01);
    try testing.expect(loaded.tracks[0].muted);

    try testing.expectEqualStrings("Bass", loaded.tracks[1].getName());
    try testing.expectApproxEqRel(@as(f32, -0.5), loaded.tracks[1].pan, 0.01);

    try testing.expectEqual(@as(u8, 1), loaded.tracks[0].clip_count);
    try testing.expectEqualStrings("Kick Pattern", loaded.tracks[0].clips[0].getName());
    try testing.expectApproxEqRel(@as(f64, 1.0), loaded.tracks[0].clips[0].start_time, 0.001);
}

test "track 7 settings and MIDI note survive save and reload" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const last: usize = project_mod.TRACK_COUNT - 1;
    try testing.expectEqual(@as(usize, 8), project_mod.TRACK_COUNT);

    midi_clip_clear(@intCast(last));
    defer midi_clip_clear(@intCast(last));
    try testing.expect(midi_clip_add_note(@intCast(last), 1.0, 0.5, 67, 100) != 0);

    var project = Project.init();
    project.tracks[last].setName("Last");
    project.tracks[last].volume = 0.4;
    project.tracks[last].pan = 0.25;
    project.tracks[last].muted = true;
    project.tracks[last].solo = true;
    project.tracks[last].armed = true;

    const dir = "persistence_track7_tmp";
    try sys.makePath(dir);
    defer std.Io.Dir.cwd().deleteTree(sys.io(), dir) catch {};
    try saveProject(allocator, &project, dir);

    // Open must replace whatever the previous session left in memory.
    midi_clip_clear(@intCast(last));
    try testing.expectEqual(@as(c_int, 0), midi_clip_has_notes(@intCast(last)));
    _ = try midi_clip_add_note_extra(@intCast(last - 1));
    defer midi_clip_clear(@intCast(last - 1));

    const loaded = try loadProject(allocator, dir);
    try testing.expectEqualStrings("Last", loaded.tracks[last].getName());
    try testing.expectApproxEqAbs(@as(f32, 0.4), loaded.tracks[last].volume, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 0.25), loaded.tracks[last].pan, 0.001);
    try testing.expect(loaded.tracks[last].muted);
    try testing.expect(loaded.tracks[last].solo);
    try testing.expect(loaded.tracks[last].armed);
    try testing.expectEqual(@as(c_int, 1), midi_clip_has_notes(@intCast(last)));
    try testing.expectEqual(@as(c_int, 1), midi_clip_get_note_count(@intCast(last)));
    // Track 6 had a stale note that was not saved; loading must clear it.
    try testing.expectEqual(@as(c_int, 0), midi_clip_has_notes(@intCast(last - 1)));
}

fn midi_clip_add_note_extra(track: c_int) !void {
    if (midi_clip_add_note(track, 0.0, 1.0, 60, 90) == 0) return error.AddNoteFailed;
}

test "every track's instrument, mixer state and name round-trip through save and load" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var project = Project.init();
    for (0..project_mod.TRACK_COUNT) |i| {
        const track = &project.tracks[i];
        var name_buf: [24]u8 = undefined;
        track.setName(std.fmt.bufPrint(&name_buf, "Voice {d}", .{i}) catch "Voice");
        // Instrument type 0 is a real instrument and must stay distinct from "none" (stored as 0).
        track.instrument_type = if (i == 0) 0 else @intCast(i);
        track.volume = 0.1 * @as(f32, @floatFromInt(i + 1));
        track.pan = -1.0 + 0.25 * @as(f32, @floatFromInt(i));
        track.muted = i % 2 == 0;
        track.solo = i % 3 == 0;
        track.armed = i % 4 == 1;
    }

    const dir = "persistence_roundtrip_tmp";
    try sys.makePath(dir);
    defer std.Io.Dir.cwd().deleteTree(sys.io(), dir) catch {};
    try saveProject(allocator, &project, dir);
    const loaded = try loadProject(allocator, dir);

    for (0..project_mod.TRACK_COUNT) |i| {
        const want = &project.tracks[i];
        const got = &loaded.tracks[i];
        try testing.expectEqualStrings(want.getName(), got.getName());
        try testing.expectEqual(want.instrument_type, got.instrument_type);
        try testing.expectApproxEqAbs(want.volume, got.volume, 0.001);
        try testing.expectApproxEqAbs(want.pan, got.pan, 0.001);
        try testing.expectEqual(want.muted, got.muted);
        try testing.expectEqual(want.solo, got.solo);
        try testing.expectEqual(want.armed, got.armed);
    }
}

test "physical model instruments round-trip through save and load" {
    const testing = std.testing;
    const allocator = testing.allocator;
    const instruments = @import("../instruments/instruments.zig");

    const models = [_]instruments.InstrumentType{ .model_piano, .model_strings, .model_pluck, .model_brass };
    var project = Project.init();
    // The model stores 0 for none and engine type + 1 otherwise (see project_set_track_instrument).
    for (models, 0..) |model, i| {
        project.tracks[i].instrument_type = @intCast(@backingInt(model) + 1);
    }

    const dir = "persistence_models_tmp";
    try sys.makePath(dir);
    defer std.Io.Dir.cwd().deleteTree(sys.io(), dir) catch {};
    try saveProject(allocator, &project, dir);
    const loaded = try loadProject(allocator, dir);

    for (models, 0..) |model, i| {
        try testing.expectEqual(@as(u8, @intCast(@backingInt(model) + 1)), loaded.tracks[i].instrument_type);
        const restored = instruments.getInstrumentType(@as(usize, loaded.tracks[i].instrument_type) - 1);
        try testing.expectEqual(@as(?instruments.InstrumentType, model), restored);
    }
    // Tracks without an instrument stay "none".
    try testing.expectEqual(@as(u8, 0), loaded.tracks[models.len].instrument_type);
}

test "save keeps a track whose MIDI exceeds 32 KB and reports a track that cannot be written" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const track: c_int = 7;
    const note_total: c_int = 2500; // 2500 * 19 bytes is well over 32 KB
    midi_clip_clear(track);
    defer midi_clip_clear(track);
    var i: c_int = 0;
    while (i < note_total) : (i += 1) {
        try testing.expect(midi_clip_add_note(track, @as(f64, @floatFromInt(i)) * 0.25, 0.25, 60, 100) != 0);
    }
    try testing.expectEqual(note_total, midi_clip_get_note_count(track));

    const dir = "persistence_bigmidi_tmp";
    try sys.makePath(dir);
    defer std.Io.Dir.cwd().deleteTree(sys.io(), dir) catch {};

    const project = Project.init();
    try saveProject(allocator, &project, dir);

    midi_clip_clear(track);
    _ = try loadProject(allocator, dir);
    try testing.expectEqual(note_total, midi_clip_get_note_count(track));

    // A track file that cannot be written must fail the save, not vanish.
    const blocked = "persistence_blockedmidi_tmp";
    try sys.makePath(blocked ++ "/midi_track7.bin");
    defer std.Io.Dir.cwd().deleteTree(sys.io(), blocked) catch {};
    try testing.expect(std.meta.isError(saveProject(allocator, &project, blocked)));
}
