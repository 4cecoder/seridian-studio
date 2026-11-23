const std = @import("std");
const Track = @import("track.zig").Track;
const AudioClip = @import("track.zig").AudioClip;
const Clip = @import("clip.zig").Clip;
const ClipId = @import("clip.zig").ClipId;
const buffer_module = @import("buffer.zig");
const RefCountedAudioBuffer = buffer_module.RefCountedAudioBuffer;

const log = std.log.scoped(.clip_sync);

/// Synchronization manager for clip timeline (ClipList) and playback buffer (AudioClip)
///
/// This implements a Primary/Replica pattern where:
/// - Primary: track.clips (ClipList) is the single source of truth
/// - Replica: track.clip (AudioClip) mirrors the active clip at playback position
/// - Synchronization: Automatic, transactional updates after ClipList modifications
pub const ClipSyncManager = struct {
    track: *Track,

    /// Configuration
    config: struct {
        /// Enable validation checks (always enabled now)
        enable_validation: bool = true,
        /// Log sync operations
        verbose_logging: bool = false,
    } = .{},

    /// Statistics for debugging
    stats: struct {
        sync_count: u64 = 0,
        validation_failures: u64 = 0,
    } = .{},

    pub fn init(track: *Track) ClipSyncManager {
        return .{
            .track = track,
        };
    }

    /// Sync AudioClip from ClipList state
    /// Called automatically after ClipList modifications
    pub fn syncFromClipList(self: *ClipSyncManager, playback_position: f64) !void {
        // Find active clip at playback position
        const active_clip = self.track.clips.getClipAt(playback_position);

        if (active_clip) |clip| {
            // Update AudioClip to match timeline clip
            try self.updateAudioClip(clip);
        } else {
            // No clip at this position - clear AudioClip
            self.clearAudioClip();
        }

        self.stats.sync_count += 1;

        if (self.config.enable_validation) {
            try self.validate();
        }

        if (self.config.verbose_logging) {
            if (active_clip) |clip| {
                log.debug("Synced: active clip id={} at position {d}s", .{ clip.id, playback_position });
            } else {
                log.debug("Synced: no active clip at position {d}s", .{playback_position});
            }
        }
    }

    /// Update AudioClip to match a timeline Clip
    fn updateAudioClip(self: *ClipSyncManager, clip: *const Clip) !void {
        // Check if we need to update AudioClip
        const needs_update = blk: {
            if (self.track.getClip()) |existing| {
                // Check if it's the same audio buffer
                if (clip.audio_samples) |new_buffer| {
                    if (existing.samples == new_buffer) {
                        // Same buffer - no update needed
                        break :blk false;
                    }
                    // Different buffer - need to update
                    break :blk true;
                } else {
                    // Clip has no audio data but AudioClip exists - clear it
                    break :blk true;
                }
            } else {
                // No AudioClip exists - create if clip has audio
                break :blk clip.audio_samples != null;
            }
        };

        if (!needs_update) {
            return;
        }

        // Create new AudioClip if clip has audio buffer
        if (clip.audio_samples) |audio_buffer| {
            audio_buffer.retain();

            const num_frames = audio_buffer.data.len / clip.audio_channels;

            const new_clip = AudioClip{
                .allocator = self.track.allocator,
                .samples = audio_buffer,
                .num_channels = clip.audio_channels,
                .sample_rate = clip.audio_sample_rate,
                .num_frames = num_frames,
            };

            // Atomic swap handled by Track
            try self.track.setClip(new_clip);

            if (self.config.verbose_logging) {
                log.debug("Created AudioClip: {} frames, {} channels, {}Hz (reference-counted)", .{
                    num_frames,
                    clip.audio_channels,
                    clip.audio_sample_rate,
                });
            }
        } else {
            // Clip has no audio data - clear AudioClip
            self.track.clearClip();
        }
    }

    /// Clear AudioClip (no active clip)
    fn clearAudioClip(self: *ClipSyncManager) void {
        if (self.track.getClip()) |_| {
            self.track.clearClip();

            if (self.config.verbose_logging) {
                log.debug("Cleared AudioClip", .{});
            }
        }
    }

    /// Validate synchronization state
    /// This runs only in debug mode and catches desync bugs early
    fn validate(self: *const ClipSyncManager) !void {
        if (!self.config.enable_validation) return;

        // Check: If AudioClip exists, there should be a matching timeline clip
        if (self.track.getClip()) |audio_clip| {
            var found = false;
            for (self.track.clips.clips.items) |*timeline_clip| {
                if (timeline_clip.audio_samples) |buffer| {
                    if (buffer == audio_clip.samples) {
                        found = true;

                        // Validate sample rate and channel consistency
                        if (timeline_clip.audio_sample_rate != audio_clip.sample_rate) {
                            log.err("Sample rate mismatch: timeline={}, audio={}", .{
                                timeline_clip.audio_sample_rate,
                                audio_clip.sample_rate,
                            });
                            return error.ClipDesyncDetected;
                        }

                        if (timeline_clip.audio_channels != audio_clip.num_channels) {
                            log.err("Channel count mismatch: timeline={}, audio={}", .{
                                timeline_clip.audio_channels,
                                audio_clip.num_channels,
                            });
                            return error.ClipDesyncDetected;
                        }

                        break;
                    }
                }
            }

            if (!found) {
                log.err("Validation failed: AudioClip exists but no matching timeline clip found", .{});
                return error.ClipDesyncDetected;
            }
        }
    }

    // --- Transactional Clip Operations ---
    // These operations modify ClipList and automatically sync AudioClip

    /// Create a clip and sync (transactional)
    pub fn addClip(self: *ClipSyncManager, clip: Clip, playback_position: f64) !ClipId {
        // Add to timeline
        const clip_id = try self.track.clips.addClip(clip);

        // Sync AudioClip
        try self.syncFromClipList(playback_position);

        return clip_id;
    }

    /// Remove a clip and sync (transactional)
    pub fn removeClip(self: *ClipSyncManager, clip_id: ClipId, playback_position: f64) !bool {
        // Remove from timeline
        const removed = self.track.clips.removeClip(clip_id);

        if (removed) {
            // Sync AudioClip - will clear if no clip at playback position
            try self.syncFromClipList(playback_position);
        }

        return removed;
    }

    /// Move clip and sync if needed
    pub fn moveClip(self: *ClipSyncManager, clip_id: ClipId, new_start: f64, playback_position: f64) !bool {
        const moved = self.track.clips.moveClip(clip_id, new_start);

        if (moved) {
            // Re-sync if the moved clip affects current playback position
            try self.syncFromClipList(playback_position);
        }

        return moved;
    }

    /// Split clip and sync
    pub fn splitClip(self: *ClipSyncManager, clip_id: ClipId, split_time: f64, playback_position: f64) !?ClipId {
        const new_id = try self.track.clips.splitClip(clip_id, split_time);

        if (new_id) |_| {
            try self.syncFromClipList(playback_position);
        }

        return new_id;
    }

    /// Runtime health check (non-panicking)
    /// Returns true if sync state is healthy
    pub fn healthCheck(self: *const ClipSyncManager) bool {
        if (self.track.getClip()) |audio_clip| {
            for (self.track.clips.clips.items) |*tc| {
                if (tc.audio_samples) |audio_buffer| {
                    if (audio_buffer == audio_clip.samples) {
                        return true;
                    }
                }
            }
            return false; // Desync detected
        }
        return true; // No AudioClip is valid
    }
};

// Tests
test "ClipSyncManager - add clip syncs AudioClip" {
    const testing = std.testing;

    var track = Track.init(testing.allocator);
    defer track.deinit();

    var sync_mgr = ClipSyncManager.init(&track);

    // Add clip with audio data (create ref-counted buffer)
    const raw_samples = [_]f32{ 1.0, 0.5, -0.5, -1.0 };
    const audio_buffer = try RefCountedAudioBuffer.create(testing.allocator, &raw_samples);
    defer audio_buffer.release();

    const clip = Clip{
        .id = 0,
        .start_time = 0.0,
        .duration = 1.0,
        .audio_samples = audio_buffer,
        .audio_channels = 2,
        .audio_sample_rate = 48000,
    };

    const clip_id = try sync_mgr.addClip(clip, 0.5);
    _ = clip_id;

    // AudioClip should exist
    try testing.expect(track.getClip() != null);
    try testing.expectEqual(@as(u32, 48000), track.getClip().?.sample_rate);
    try testing.expectEqual(@as(u16, 2), track.getClip().?.num_channels);
}

test "ClipSyncManager - remove clip clears AudioClip" {
    const testing = std.testing;

    var track = Track.init(testing.allocator);
    defer track.deinit();

    var sync_mgr = ClipSyncManager.init(&track);

    // Add clip
    const raw_samples = [_]f32{ 1.0, 0.5, -0.5, -1.0 };
    const audio_buffer = try RefCountedAudioBuffer.create(testing.allocator, &raw_samples);
    defer audio_buffer.release();

    const clip = Clip{
        .id = 0,
        .start_time = 0.0,
        .duration = 1.0,
        .audio_samples = audio_buffer,
        .audio_channels = 2,
        .audio_sample_rate = 48000,
    };

    const clip_id = try sync_mgr.addClip(clip, 0.5);

    // Verify AudioClip exists
    try testing.expect(track.getClip() != null);

    // Remove clip
    _ = try sync_mgr.removeClip(clip_id, 0.5);

    // AudioClip should be cleared
    try testing.expect(track.getClip() == null);
}

test "ClipSyncManager - validation catches desync" {
    const testing = std.testing;

    var track = Track.init(testing.allocator);
    defer track.deinit();

    var sync_mgr = ClipSyncManager.init(&track);

    // Add clip
    const raw_samples = [_]f32{ 1.0, 0.5, -0.5, -1.0 };
    const audio_buffer = try RefCountedAudioBuffer.create(testing.allocator, &raw_samples);
    defer audio_buffer.release();

    const clip = Clip{
        .id = 0,
        .start_time = 0.0,
        .duration = 1.0,
        .audio_samples = audio_buffer,
        .audio_channels = 2,
        .audio_sample_rate = 48000,
    };

    _ = try sync_mgr.addClip(clip, 0.5);

    // Manually corrupt sync state (simulate bug)
    const corrupt_samples = try testing.allocator.alloc(f32, 100);
    defer testing.allocator.free(corrupt_samples);

    if (track.getClip()) |audio_clip| {
        audio_clip.samples.release();
        audio_clip.samples = try RefCountedAudioBuffer.create(testing.allocator, corrupt_samples);
    }

    // Validation should catch this
    try testing.expectError(error.ClipDesyncDetected, sync_mgr.validate());
}

test "ClipSyncManager - health check" {
    const testing = std.testing;

    var track = Track.init(testing.allocator);
    defer track.deinit();

    var sync_mgr = ClipSyncManager.init(&track);

    // Health check with no clips should pass
    try testing.expect(sync_mgr.healthCheck());

    // Add clip
    const raw_samples = [_]f32{ 1.0, 0.5 };
    const audio_buffer = try RefCountedAudioBuffer.create(testing.allocator, &raw_samples);
    defer audio_buffer.release();

    const clip = Clip{
        .id = 0,
        .start_time = 0.0,
        .duration = 1.0,
        .audio_samples = audio_buffer,
        .audio_channels = 1,
        .audio_sample_rate = 48000,
    };

    _ = try sync_mgr.addClip(clip, 0.5);

    // Health check should pass
    try testing.expect(sync_mgr.healthCheck());
}
