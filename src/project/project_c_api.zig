//! C API for Project Session Management
//!
//! Allows GTK/C code to save/load projects through exported functions.

const std = @import("std");
const sys = @import("../utils/sys.zig");
const project_mod = @import("project_mod.zig");
const Project = project_mod.Project;
const persistence = project_mod.persistence;

const log = std.log.scoped(.project_c_api);

// =============================================================================
// Global Project State
// =============================================================================

/// Global project state (singleton for C access)
var g_project: ?*Project = null;
var g_allocator: ?std.mem.Allocator = null;
var g_folder_path: ?[]const u8 = null;

// =============================================================================
// Initialization
// =============================================================================

/// Initialize project system with allocator
pub export fn project_init(allocator_ptr: ?*anyopaque) callconv(.c) c_int {
    if (allocator_ptr) |ptr| {
        const alloc_holder = @as(*std.mem.Allocator, @ptrCast(@alignCast(ptr)));
        g_allocator = alloc_holder.*;

        // Create default project
        const project = g_allocator.?.create(Project) catch {
            log.err("Failed to allocate project", .{});
            return -1;
        };
        project.* = Project.init();
        g_project = project;

        log.info("Project system initialized", .{});
        return 0;
    }
    return -1;
}

/// Shutdown project system
pub export fn project_deinit() callconv(.c) void {
    if (g_project) |project| {
        if (g_allocator) |allocator| {
            allocator.destroy(project);
        }
    }
    if (g_folder_path) |path| {
        if (g_allocator) |allocator| {
            allocator.free(path);
        }
    }
    g_project = null;
    g_folder_path = null;
    g_allocator = null;
    log.info("Project system shutdown", .{});
}

// =============================================================================
// Project State Access
// =============================================================================

/// Get project name
export fn project_get_name() callconv(.c) [*:0]const u8 {
    if (g_project) |project| {
        return @ptrCast(project.header.name[0..].ptr);
    }
    return "Untitled";
}

/// Set project name
export fn project_set_name(name: [*:0]const u8) callconv(.c) void {
    if (g_project) |project| {
        const name_slice = std.mem.span(name);
        project.header.setName(name_slice);
        project.markDirty();
    }
}

/// Get BPM
export fn project_get_bpm() callconv(.c) f32 {
    if (g_project) |project| {
        return project.header.bpm;
    }
    return 120.0;
}

/// Set BPM
export fn project_set_bpm(bpm: f32) callconv(.c) void {
    if (g_project) |project| {
        project.header.bpm = std.math.clamp(bpm, 20.0, 300.0);
        project.markDirty();
    }
}

/// Get time signature numerator
export fn project_get_time_sig_num() callconv(.c) c_int {
    if (g_project) |project| {
        return project.header.time_sig_num;
    }
    return 4;
}

/// Get time signature denominator
export fn project_get_time_sig_den() callconv(.c) c_int {
    if (g_project) |project| {
        return project.header.time_sig_den;
    }
    return 4;
}

/// Set time signature
export fn project_set_time_sig(num: c_int, den: c_int) callconv(.c) void {
    if (g_project) |project| {
        project.header.time_sig_num = @intCast(std.math.clamp(num, 1, 16));
        project.header.time_sig_den = @intCast(std.math.clamp(den, 1, 16));
        project.markDirty();
    }
}

/// Get master volume
export fn project_get_master_volume() callconv(.c) f32 {
    if (g_project) |project| {
        return project.header.master_volume;
    }
    return 0.75;
}

/// Set master volume
export fn project_set_master_volume(volume: f32) callconv(.c) void {
    if (g_project) |project| {
        project.header.master_volume = std.math.clamp(volume, 0.0, 1.0);
        project.markDirty();
    }
}

/// Check if project has unsaved changes
export fn project_is_dirty() callconv(.c) c_int {
    if (g_project) |project| {
        return if (project.dirty) 1 else 0;
    }
    return 0;
}

/// Check if project has a save location
export fn project_has_save_location() callconv(.c) c_int {
    return if (g_folder_path != null) 1 else 0;
}

// =============================================================================
// Track State Access
// =============================================================================

/// Get track name
export fn project_get_track_name(track: c_int) callconv(.c) [*:0]const u8 {
    if (g_project) |project| {
        if (track >= 0 and track < project_mod.TRACK_COUNT) {
            return @ptrCast(project.tracks[@intCast(track)].name[0..].ptr);
        }
    }
    return "Track";
}

/// Set track name
export fn project_set_track_name(track: c_int, name: [*:0]const u8) callconv(.c) void {
    if (g_project) |project| {
        if (track >= 0 and track < project_mod.TRACK_COUNT) {
            const name_slice = std.mem.span(name);
            project.tracks[@intCast(track)].setName(name_slice);
            project.markDirty();
        }
    }
}

/// Get track volume
export fn project_get_track_volume(track: c_int) callconv(.c) f32 {
    if (g_project) |project| {
        if (track >= 0 and track < project_mod.TRACK_COUNT) {
            return project.tracks[@intCast(track)].volume;
        }
    }
    return 0.75;
}

/// Set track volume
export fn project_set_track_volume(track: c_int, volume: f32) callconv(.c) void {
    if (g_project) |project| {
        if (track >= 0 and track < project_mod.TRACK_COUNT) {
            project.tracks[@intCast(track)].volume = std.math.clamp(volume, 0.0, 1.0);
            project.markDirty();
        }
    }
}

/// Get track pan
export fn project_get_track_pan(track: c_int) callconv(.c) f32 {
    if (g_project) |project| {
        if (track >= 0 and track < project_mod.TRACK_COUNT) {
            return project.tracks[@intCast(track)].pan;
        }
    }
    return 0.0;
}

/// Set track pan
export fn project_set_track_pan(track: c_int, pan: f32) callconv(.c) void {
    if (g_project) |project| {
        if (track >= 0 and track < project_mod.TRACK_COUNT) {
            project.tracks[@intCast(track)].pan = std.math.clamp(pan, -1.0, 1.0);
            project.markDirty();
        }
    }
}

/// Get track muted state
export fn project_get_track_muted(track: c_int) callconv(.c) c_int {
    if (g_project) |project| {
        if (track >= 0 and track < project_mod.TRACK_COUNT) {
            return if (project.tracks[@intCast(track)].muted) 1 else 0;
        }
    }
    return 0;
}

/// Set track muted state
export fn project_set_track_muted(track: c_int, muted: c_int) callconv(.c) void {
    if (g_project) |project| {
        if (track >= 0 and track < project_mod.TRACK_COUNT) {
            project.tracks[@intCast(track)].muted = muted != 0;
            project.markDirty();
        }
    }
}

/// Get track solo state
export fn project_get_track_solo(track: c_int) callconv(.c) c_int {
    if (g_project) |project| {
        if (track >= 0 and track < project_mod.TRACK_COUNT) {
            return if (project.tracks[@intCast(track)].solo) 1 else 0;
        }
    }
    return 0;
}

/// Set track solo state
export fn project_set_track_solo(track: c_int, solo: c_int) callconv(.c) void {
    if (g_project) |project| {
        if (track >= 0 and track < project_mod.TRACK_COUNT) {
            project.tracks[@intCast(track)].solo = solo != 0;
            project.markDirty();
        }
    }
}

/// Get track record-arm state
export fn project_get_track_armed(track: c_int) callconv(.c) c_int {
    if (g_project) |project| {
        if (track >= 0 and track < project_mod.TRACK_COUNT) {
            return if (project.tracks[@intCast(track)].armed) 1 else 0;
        }
    }
    return 0;
}

/// Set track record-arm state
export fn project_set_track_armed(track: c_int, armed: c_int) callconv(.c) void {
    if (g_project) |project| {
        if (track >= 0 and track < project_mod.TRACK_COUNT) {
            project.tracks[@intCast(track)].armed = armed != 0;
            project.markDirty();
        }
    }
}

/// Get the track's instrument as an engine instrument type, or -1 for none.
/// The model stores 0 for none and type + 1 otherwise, so type 0 stays distinct from "no instrument".
export fn project_get_track_instrument(track: c_int) callconv(.c) c_int {
    if (g_project) |project| {
        if (track >= 0 and track < project_mod.TRACK_COUNT) {
            return @as(c_int, project.tracks[@intCast(track)].instrument_type) - 1;
        }
    }
    return -1;
}

/// Set the track's instrument from an engine instrument type; a negative value means none.
export fn project_set_track_instrument(track: c_int, instrument_type: c_int) callconv(.c) void {
    if (g_project) |project| {
        if (track >= 0 and track < project_mod.TRACK_COUNT) {
            project.tracks[@intCast(track)].instrument_type = if (instrument_type < 0 or instrument_type >= std.math.maxInt(u8))
                0
            else
                @intCast(instrument_type + 1);
            project.markDirty();
        }
    }
}

// =============================================================================
// Save / Load
// =============================================================================

/// Create new project (clears current state)
export fn project_new() callconv(.c) c_int {
    if (g_project) |project| {
        // Reset to defaults
        project.* = Project.init();

        // Clear folder path
        if (g_folder_path) |path| {
            if (g_allocator) |allocator| {
                allocator.free(path);
            }
        }
        g_folder_path = null;

        log.info("New project created", .{});
        return 0;
    }
    return -1;
}

/// Save project to folder path (null = use current path)
/// Returns 0 on success, -1 on error
export fn project_save(folder_path_ptr: ?[*:0]const u8) callconv(.c) c_int {
    const allocator = g_allocator orelse return -1;
    const project = g_project orelse return -1;

    // Determine path
    const path: []const u8 = if (folder_path_ptr) |ptr|
        std.mem.span(ptr)
    else if (g_folder_path) |existing|
        existing
    else
        return -1; // No path specified and no existing path

    // Save project
    persistence.saveProject(allocator, project, path) catch |err| {
        log.err("Failed to save project: {}", .{err});
        return -1;
    };

    // Update folder path if new
    if (folder_path_ptr != null and g_folder_path == null) {
        g_folder_path = allocator.dupe(u8, path) catch null;
    }

    project.clearDirty();
    return 0;
}

/// Save project to new folder (Save As)
export fn project_save_as(folder_path: [*:0]const u8) callconv(.c) c_int {
    const allocator = g_allocator orelse return -1;
    const project = g_project orelse return -1;
    const path = std.mem.span(folder_path);

    // Create folder structure
    sys.makePath(path) catch |err| {
        log.err("Failed to create project folder: {}", .{err});
        return -1;
    };

    // Create Audio subfolder
    var audio_path_buf: [512]u8 = undefined;
    const audio_path = std.fmt.bufPrint(&audio_path_buf, "{s}/Audio", .{path}) catch return -1;
    sys.makePath(audio_path) catch {};

    // Set project name from folder name if currently "Untitled"
    const current_name = std.mem.sliceTo(&project.header.name, 0);
    if (current_name.len == 0 or std.mem.eql(u8, current_name, "Untitled")) {
        const folder_name = std.fs.path.basename(path);
        if (folder_name.len > 0) {
            project.header.setName(folder_name);
            log.info("Set project name from folder: {s}", .{folder_name});
        }
    }

    // Save project
    persistence.saveProject(allocator, project, path) catch |err| {
        log.err("Failed to save project: {}", .{err});
        return -1;
    };

    // Update folder path
    if (g_folder_path) |old_path| {
        allocator.free(old_path);
    }
    g_folder_path = allocator.dupe(u8, path) catch null;

    project.clearDirty();
    log.info("Project saved as: {s}", .{path});
    return 0;
}

/// Load project from folder
export fn project_load(folder_path: [*:0]const u8) callconv(.c) c_int {
    const allocator = g_allocator orelse return -1;
    const project = g_project orelse return -1;
    const path = std.mem.span(folder_path);

    // Load project
    const loaded = persistence.loadProject(allocator, path) catch |err| {
        log.err("Failed to load project: {}", .{err});
        return -1;
    };

    // Update project state
    project.* = loaded;
    project.clearDirty();

    // Extract project name from folder path if current name is empty or "Untitled"
    const current_name = std.mem.sliceTo(&project.header.name, 0);
    if (current_name.len == 0 or std.mem.eql(u8, current_name, "Untitled")) {
        // Get folder name from path (last component)
        const folder_name = std.fs.path.basename(path);
        if (folder_name.len > 0) {
            project.header.setName(folder_name);
            log.info("Set project name from folder: {s}", .{folder_name});
        }
    }

    // Update folder path
    if (g_folder_path) |old_path| {
        allocator.free(old_path);
    }
    g_folder_path = allocator.dupe(u8, path) catch null;

    log.info("Project loaded: {s}", .{path});
    return 0;
}

/// Save a copy of the project to a folder without changing the current save location or the dirty flag.
/// Used by autosave so the user's own session folder is never written. Returns 0 on success.
export fn project_save_copy(folder_path: [*:0]const u8) callconv(.c) c_int {
    const allocator = g_allocator orelse return -1;
    const project = g_project orelse return -1;
    const path = std.mem.span(folder_path);
    sys.makePath(path) catch |err| {
        log.err("Failed to create copy folder: {}", .{err});
        return -1;
    };
    persistence.saveProject(allocator, project, path) catch |err| {
        log.err("Failed to save project copy: {}", .{err});
        return -1;
    };
    return 0;
}

/// Load a project from a folder as an unsaved session: the save location is cleared and the project is
/// marked dirty, so Save asks for a folder instead of overwriting the loaded copy. Used for recovery.
export fn project_load_unsaved(folder_path: [*:0]const u8) callconv(.c) c_int {
    const allocator = g_allocator orelse return -1;
    const project = g_project orelse return -1;
    const path = std.mem.span(folder_path);
    const loaded = persistence.loadProject(allocator, path) catch |err| {
        log.err("Failed to load recovery copy: {}", .{err});
        return -1;
    };
    project.* = loaded;
    if (g_folder_path) |old_path| allocator.free(old_path);
    g_folder_path = null;
    project.folder_path = null;
    project.markDirty();
    return 0;
}

/// Get current project folder path (null if unsaved)
export fn project_get_folder_path() callconv(.c) ?[*:0]const u8 {
    if (g_folder_path) |path| {
        // Return as null-terminated (may need to copy in real usage)
        return @ptrCast(path.ptr);
    }
    return null;
}

// =============================================================================
// Tests
// =============================================================================

test "project_get_track_name returns saved name for all tracks" {
    var allocator: std.mem.Allocator = std.testing.allocator;
    try std.testing.expectEqual(@as(c_int, 0), project_init(@ptrCast(&allocator)));
    defer project_deinit();

    project_set_track_name(7, "Lead Synth");
    try std.testing.expectEqualStrings("Lead Synth", std.mem.span(project_get_track_name(7)));

    project_set_track_name(4, "Pad");
    try std.testing.expectEqualStrings("Pad", std.mem.span(project_get_track_name(4)));
}

test "track mixer state is stored through the C API" {
    var allocator: std.mem.Allocator = std.testing.allocator;
    try std.testing.expectEqual(@as(c_int, 0), project_init(@ptrCast(&allocator)));
    defer project_deinit();

    try std.testing.expectEqual(@as(c_int, -1), project_get_track_instrument(0));
    project_set_track_instrument(0, 0);
    try std.testing.expectEqual(@as(c_int, 0), project_get_track_instrument(0));
    project_set_track_instrument(0, -1);
    try std.testing.expectEqual(@as(c_int, -1), project_get_track_instrument(0));
    project_set_track_instrument(3, 2);
    try std.testing.expectEqual(@as(c_int, 2), project_get_track_instrument(3));

    project_set_track_armed(5, 1);
    try std.testing.expectEqual(@as(c_int, 1), project_get_track_armed(5));
    project_set_track_armed(5, 0);
    try std.testing.expectEqual(@as(c_int, 0), project_get_track_armed(5));
}
