//! MIDI Clip - Editable MIDI note storage for piano roll
//!
//! Stores MIDI notes per clip with full editing capabilities:
//! - Add/remove notes
//! - Move notes (time and pitch)
//! - Resize notes (duration)
//! - Velocity editing
//! - Selection tracking
//! - Quantization

const std = @import("std");
const sys = @import("../utils/sys.zig");
const log = std.log.scoped(.midi_clip);

/// Unique note identifier
pub const NoteId = u32;

/// A single MIDI note
pub const MidiNote = struct {
    id: NoteId = 0,
    /// Start time in beats (relative to clip start)
    start_beat: f64 = 0.0,
    /// Duration in beats
    duration_beats: f64 = 0.25,
    /// MIDI note number (0-127)
    pitch: u8 = 60,
    /// Velocity (1-127, 0 = use default)
    velocity: u8 = 100,
    /// Is this note selected?
    selected: bool = false,
    /// Is this note muted?
    muted: bool = false,

    /// Get end beat
    pub fn endBeat(self: *const MidiNote) f64 {
        return self.start_beat + self.duration_beats;
    }

    /// Check if note overlaps with a beat range
    pub fn overlapsRange(self: *const MidiNote, start: f64, end: f64) bool {
        return self.start_beat < end and self.endBeat() > start;
    }

    /// Check if a point is within this note's bounds
    pub fn containsPoint(self: *const MidiNote, beat: f64, note_pitch: u8) bool {
        return beat >= self.start_beat and
            beat < self.endBeat() and
            self.pitch == note_pitch;
    }
};

/// A note as playback sees it: timeline position (clip start already added), never muted.
pub const PlaybackNote = struct {
    start_beat: f64,
    end_beat: f64,
    pitch: u8,
    velocity: u8,
};

/// Immutable copy of a clip's audible notes. Control threads build and publish one after every
/// edit; readers (the audio thread, offline renders) only ever see a complete snapshot.
pub const Snapshot = struct {
    notes: []PlaybackNote,
};

/// Who reads a published snapshot. Each reader announces the snapshot it is reading in its own
/// slot (a hazard pointer), so the writer frees an old snapshot only once no slot names it.
pub const Reader = enum(u2) {
    /// The real-time audio callback.
    audio,
    /// Offline renders (export), which run on a control thread.
    offline,
    /// The C query API on any other thread.
    control,
};
const READER_COUNT = std.enums.values(Reader).len;

/// MIDI note list for a clip.
///
/// Editing happens on control threads, serialised by `edit_lock`. Every edit that changes what
/// plays republishes an immutable `Snapshot` through an atomic pointer. Playback reads only the
/// snapshot and never takes a lock, so editing a clip during playback cannot stall the audio
/// thread, and the audio thread never sees a half-edited note list.
pub const MidiNoteList = struct {
    allocator: std.mem.Allocator,
    notes: std.ArrayList(MidiNote),
    next_id: NoteId = 1,

    /// Clip position in timeline (beats from start)
    clip_start_beat: f64 = 0.0,

    /// Clip duration in beats (for display purposes)
    clip_duration_beats: f64 = 4.0,

    /// Tempo for time conversion (BPM)
    tempo: f64 = 120.0,

    /// Serialises editors (control threads only; the audio thread never takes it).
    edit_lock: sys.SpinLock = .{},

    /// Latest published playback snapshot (null until the first publish).
    published: std.atomic.Value(?*Snapshot) = std.atomic.Value(?*Snapshot).init(null),
    /// Snapshot each reader is currently reading (null when not reading).
    reading: [READER_COUNT]std.atomic.Value(?*Snapshot) = @splat(std.atomic.Value(?*Snapshot).init(null)),

    pub fn init(allocator: std.mem.Allocator) MidiNoteList {
        return .{
            .allocator = allocator,
            .notes = .empty,
        };
    }

    pub fn deinit(self: *MidiNoteList) void {
        if (self.published.swap(null, .seq_cst)) |old| self.retire(old);
        self.notes.deinit(self.allocator);
    }

    // ---- Control threads (with edit_lock held, or single-threaded) ----

    /// Builds a snapshot of the audible notes and publishes it, then frees the previous one once
    /// no reader holds it. On allocation failure the previous snapshot stays in force.
    pub fn publish(self: *MidiNoteList) error{OutOfMemory}!void {
        var audible: usize = 0;
        for (self.notes.items) |n| {
            if (!n.muted) audible += 1;
        }
        const snapshot = try self.allocator.create(Snapshot);
        errdefer self.allocator.destroy(snapshot);
        const notes = try self.allocator.alloc(PlaybackNote, audible);
        var i: usize = 0;
        for (self.notes.items) |n| {
            if (n.muted) continue;
            notes[i] = .{
                .start_beat = self.clip_start_beat + n.start_beat,
                .end_beat = self.clip_start_beat + n.endBeat(),
                .pitch = n.pitch,
                .velocity = n.velocity,
            };
            i += 1;
        }
        snapshot.* = .{ .notes = notes };
        if (self.published.swap(snapshot, .seq_cst)) |old| self.retire(old);
    }

    /// Frees an unpublished snapshot once no reader slot names it. A reader holds a snapshot for
    /// one query at most, so this waits at most that long.
    fn retire(self: *MidiNoteList, old: *Snapshot) void {
        for (&self.reading) |*slot| {
            while (slot.load(.seq_cst) == old) std.Thread.yield() catch std.atomic.spinLoopHint();
        }
        self.allocator.free(old.notes);
        self.allocator.destroy(old);
    }

    // ---- Readers (lock-free, no allocation) ----

    /// Announces and returns the current snapshot for `reader`; pair with `release`.
    /// Each `Reader` value must be used by one thread at a time.
    pub fn acquire(self: *MidiNoteList, reader: Reader) ?*const Snapshot {
        const slot = &self.reading[@backingInt(reader)];
        while (true) {
            const current = self.published.load(.seq_cst);
            slot.store(current, .seq_cst);
            // Re-check: if a writer swapped in between, it may already be freeing `current`.
            if (self.published.load(.seq_cst) == current) return current;
        }
    }

    /// Ends the read started by `acquire`.
    pub fn release(self: *MidiNoteList, reader: Reader) void {
        self.reading[@backingInt(reader)].store(null, .seq_cst);
    }

    /// Number of audible notes playback sees. Lock-free.
    pub fn playbackCount(self: *MidiNoteList, reader: Reader) usize {
        const snapshot = self.acquire(reader) orelse return 0;
        defer self.release(reader);
        return snapshot.notes.len;
    }

    /// Add a new note, returns its ID
    pub fn addNote(self: *MidiNoteList, note: MidiNote) !NoteId {
        var new_note = note;
        new_note.id = self.next_id;
        self.next_id += 1;

        try self.notes.append(self.allocator, new_note);
        log.debug("Added note id={} pitch={} at beat {d:.2}", .{
            new_note.id,
            new_note.pitch,
            new_note.start_beat,
        });
        return new_note.id;
    }

    /// Remove a note by ID
    pub fn removeNote(self: *MidiNoteList, id: NoteId) bool {
        for (self.notes.items, 0..) |n, i| {
            if (n.id == id) {
                _ = self.notes.orderedRemove(i);
                log.debug("Removed note id={}", .{id});
                return true;
            }
        }
        return false;
    }

    /// Get note by ID
    pub fn getNote(self: *MidiNoteList, id: NoteId) ?*MidiNote {
        for (self.notes.items) |*n| {
            if (n.id == id) {
                return n;
            }
        }
        return null;
    }

    /// Get note by index
    pub fn getNoteByIndex(self: *MidiNoteList, index: usize) ?*MidiNote {
        if (index < self.notes.items.len) {
            return &self.notes.items[index];
        }
        return null;
    }

    /// Get note count
    pub fn count(self: *const MidiNoteList) usize {
        return self.notes.items.len;
    }

    /// Find note at a specific beat and pitch
    pub fn findNoteAt(self: *MidiNoteList, beat: f64, pitch: u8) ?*MidiNote {
        // Search backwards to find topmost note first
        var i = self.notes.items.len;
        while (i > 0) {
            i -= 1;
            const n = &self.notes.items[i];
            if (n.containsPoint(beat, pitch)) {
                return n;
            }
        }
        return null;
    }

    /// Move a note to a new position
    pub fn moveNote(self: *MidiNoteList, id: NoteId, new_beat: f64, new_pitch: u8) bool {
        if (self.getNote(id)) |n| {
            n.start_beat = @max(0.0, new_beat);
            n.pitch = @min(127, new_pitch);
            return true;
        }
        return false;
    }

    /// Resize a note (change duration)
    pub fn resizeNote(self: *MidiNoteList, id: NoteId, new_duration: f64) bool {
        if (self.getNote(id)) |n| {
            n.duration_beats = @max(0.0625, new_duration); // Minimum 1/16th beat
            return true;
        }
        return false;
    }

    /// Set note velocity
    pub fn setVelocity(self: *MidiNoteList, id: NoteId, velocity: u8) bool {
        if (self.getNote(id)) |n| {
            n.velocity = @max(1, @min(127, velocity));
            return true;
        }
        return false;
    }

    /// Select/deselect a note
    pub fn setSelected(self: *MidiNoteList, id: NoteId, selected: bool) bool {
        if (self.getNote(id)) |n| {
            n.selected = selected;
            return true;
        }
        return false;
    }

    /// Select all notes
    pub fn selectAll(self: *MidiNoteList) void {
        for (self.notes.items) |*n| {
            n.selected = true;
        }
    }

    /// Deselect all notes
    pub fn deselectAll(self: *MidiNoteList) void {
        for (self.notes.items) |*n| {
            n.selected = false;
        }
    }

    /// Get selected note count
    pub fn selectedCount(self: *const MidiNoteList) usize {
        var cnt: usize = 0;
        for (self.notes.items) |n| {
            if (n.selected) cnt += 1;
        }
        return cnt;
    }

    /// Delete all selected notes
    pub fn deleteSelected(self: *MidiNoteList) usize {
        var deleted: usize = 0;
        var i: usize = 0;
        while (i < self.notes.items.len) {
            if (self.notes.items[i].selected) {
                _ = self.notes.orderedRemove(i);
                deleted += 1;
            } else {
                i += 1;
            }
        }
        return deleted;
    }

    /// Move all selected notes by delta
    pub fn moveSelected(self: *MidiNoteList, delta_beat: f64, delta_pitch: i32) void {
        for (self.notes.items) |*n| {
            if (n.selected) {
                n.start_beat = @max(0.0, n.start_beat + delta_beat);
                const new_pitch = @as(i32, n.pitch) + delta_pitch;
                n.pitch = @intCast(@max(0, @min(127, new_pitch)));
            }
        }
    }

    /// Set velocity for all selected notes
    pub fn setSelectedVelocity(self: *MidiNoteList, velocity: u8) void {
        for (self.notes.items) |*n| {
            if (n.selected) {
                n.velocity = @max(1, @min(127, velocity));
            }
        }
    }

    /// Quantize selected notes to grid
    pub fn quantizeSelected(self: *MidiNoteList, grid_beats: f64) void {
        if (grid_beats <= 0) return;

        for (self.notes.items) |*n| {
            if (n.selected) {
                // Quantize start time
                n.start_beat = @round(n.start_beat / grid_beats) * grid_beats;
                // Optionally quantize duration
                n.duration_beats = @max(grid_beats, @round(n.duration_beats / grid_beats) * grid_beats);
            }
        }
    }

    /// Quantize all notes to grid
    pub fn quantizeAll(self: *MidiNoteList, grid_beats: f64) void {
        if (grid_beats <= 0) return;

        for (self.notes.items) |*n| {
            n.start_beat = @round(n.start_beat / grid_beats) * grid_beats;
            n.duration_beats = @max(grid_beats, @round(n.duration_beats / grid_beats) * grid_beats);
        }
    }

    /// Select notes in a rectangle (beat range + pitch range)
    pub fn selectInRect(self: *MidiNoteList, beat_start: f64, beat_end: f64, pitch_low: u8, pitch_high: u8, add_to_selection: bool) void {
        for (self.notes.items) |*n| {
            const in_rect = n.overlapsRange(beat_start, beat_end) and
                n.pitch >= pitch_low and n.pitch <= pitch_high;

            if (in_rect) {
                n.selected = true;
            } else if (!add_to_selection) {
                n.selected = false;
            }
        }
    }

    /// Get notes overlapping a beat range
    pub fn getNotesInRange(self: *const MidiNoteList, start: f64, end: f64) []const MidiNote {
        // For now, return all - caller filters
        _ = start;
        _ = end;
        return self.notes.items;
    }

    /// Clear all notes
    pub fn clear(self: *MidiNoteList) void {
        self.notes.clearRetainingCapacity();
    }

    /// Get duration based on last note end
    pub fn getDuration(self: *const MidiNoteList) f64 {
        var max_end: f64 = 0.0;
        for (self.notes.items) |n| {
            const end = n.endBeat();
            if (end > max_end) max_end = end;
        }
        return max_end;
    }

    /// Convert beats to seconds using tempo
    pub fn beatsToSeconds(self: *const MidiNoteList, beats: f64) f64 {
        return beats * 60.0 / self.tempo;
    }

    /// Convert seconds to beats using tempo
    pub fn secondsToBeats(self: *const MidiNoteList, seconds: f64) f64 {
        return seconds * self.tempo / 60.0;
    }
};

// =============================================================================
// Track MIDI Data Storage
// =============================================================================

/// Maximum tracks with MIDI data
const MAX_TRACKS = 16;

/// Global MIDI note storage per track
/// Created on a control thread and never freed, so a pointer read here stays valid.
var g_track_midi: [MAX_TRACKS]std.atomic.Value(?*MidiNoteList) = @splat(std.atomic.Value(?*MidiNoteList).init(null));
var g_allocator: ?std.mem.Allocator = null;

fn ensureAllocator() std.mem.Allocator {
    if (g_allocator == null) {
        // Use page allocator for simplicity
        g_allocator = std.heap.page_allocator;
    }
    return g_allocator.?;
}

fn getTrackMidi(track: usize) ?*MidiNoteList {
    if (track >= MAX_TRACKS) return null;
    return g_track_midi[track].load(.acquire);
}

/// Control threads only (allocates).
fn getOrCreateTrackMidi(track: usize) ?*MidiNoteList {
    if (track >= MAX_TRACKS) return null;
    if (g_track_midi[track].load(.acquire)) |existing| return existing;

    const allocator = ensureAllocator();
    const midi = allocator.create(MidiNoteList) catch return null;
    midi.* = MidiNoteList.init(allocator);
    if (g_track_midi[track].cmpxchgStrong(null, midi, .acq_rel, .acquire)) |winner| {
        // Another control thread created it first.
        midi.deinit();
        allocator.destroy(midi);
        return winner;
    }
    log.info("Created MIDI note list for track {}", .{track});
    return midi;
}

/// Republishes the playback snapshot and releases the edit lock taken with `edit_lock.lock()`.
fn endEdit(midi: *MidiNoteList) void {
    midi.publish() catch |err| log.err("MIDI clip edit not published to playback: {}", .{err});
    midi.edit_lock.unlock();
}

/// Track index as a usize, or null when negative or out of range.
fn trackIndex(track: c_int) ?usize {
    if (track < 0 or track >= MAX_TRACKS) return null;
    return @intCast(track);
}

// =============================================================================
// C API
// =============================================================================

/// Get note count for a track
pub export fn midi_clip_get_note_count(track: c_int) callconv(.c) c_int {
    const midi = getTrackMidi(@intCast(track)) orelse return 0;
    return @intCast(midi.count());
}

/// Get note data by index
/// Returns: 1 on success, 0 on failure
pub export fn midi_clip_get_note(
    track: c_int,
    index: c_int,
    out_id: *u32,
    out_start_beat: *f64,
    out_duration: *f64,
    out_pitch: *u8,
    out_velocity: *u8,
    out_selected: *c_int,
) callconv(.c) c_int {
    // Handle invalid indices
    if (track < 0 or index < 0) return 0;

    const midi = getTrackMidi(@intCast(track)) orelse return 0;
    const note = midi.getNoteByIndex(@intCast(index)) orelse return 0;

    out_id.* = note.id;
    out_start_beat.* = note.start_beat;
    out_duration.* = note.duration_beats;
    out_pitch.* = note.pitch;
    out_velocity.* = note.velocity;
    out_selected.* = if (note.selected) 1 else 0;

    return 1;
}

/// Add a new note
/// Returns: note ID on success, 0 on failure
/// Control threads: serialised with other editors; republishes the playback snapshot
pub export fn midi_clip_add_note(
    track: c_int,
    start_beat: f64,
    duration: f64,
    pitch: u8,
    velocity: u8,
) callconv(.c) u32 {
    const midi = getOrCreateTrackMidi(@intCast(track)) orelse return 0;

    midi.edit_lock.lock();
    defer endEdit(midi);

    const note = MidiNote{
        .start_beat = start_beat,
        .duration_beats = duration,
        .pitch = pitch,
        .velocity = velocity,
    };

    return midi.addNote(note) catch 0;
}

/// Remove a note by ID
/// Control threads: serialised with other editors; republishes the playback snapshot
pub export fn midi_clip_remove_note(track: c_int, note_id: u32) callconv(.c) c_int {
    const midi = getTrackMidi(@intCast(track)) orelse return 0;
    midi.edit_lock.lock();
    defer endEdit(midi);
    return if (midi.removeNote(note_id)) 1 else 0;
}

/// Move a note to new position
/// Control threads: serialised with other editors; republishes the playback snapshot
pub export fn midi_clip_move_note(
    track: c_int,
    note_id: u32,
    new_beat: f64,
    new_pitch: u8,
) callconv(.c) c_int {
    const midi = getTrackMidi(@intCast(track)) orelse return 0;
    midi.edit_lock.lock();
    defer endEdit(midi);
    return if (midi.moveNote(note_id, new_beat, new_pitch)) 1 else 0;
}

/// Resize a note (change duration)
/// Control threads: serialised with other editors; republishes the playback snapshot
pub export fn midi_clip_resize_note(
    track: c_int,
    note_id: u32,
    new_duration: f64,
) callconv(.c) c_int {
    const midi = getTrackMidi(@intCast(track)) orelse return 0;
    midi.edit_lock.lock();
    defer endEdit(midi);
    return if (midi.resizeNote(note_id, new_duration)) 1 else 0;
}

/// Set note velocity
/// Control threads: serialised with other editors; republishes the playback snapshot
pub export fn midi_clip_set_velocity(
    track: c_int,
    note_id: u32,
    velocity: u8,
) callconv(.c) c_int {
    const midi = getTrackMidi(@intCast(track)) orelse return 0;
    midi.edit_lock.lock();
    defer endEdit(midi);
    return if (midi.setVelocity(note_id, velocity)) 1 else 0;
}

/// Select/deselect a note
pub export fn midi_clip_set_selected(
    track: c_int,
    note_id: u32,
    selected: c_int,
) callconv(.c) c_int {
    const midi = getTrackMidi(@intCast(track)) orelse return 0;
    return if (midi.setSelected(note_id, selected != 0)) 1 else 0;
}

/// Find note at position
/// Returns: note ID or 0 if not found
pub export fn midi_clip_find_note_at(
    track: c_int,
    beat: f64,
    pitch: u8,
) callconv(.c) u32 {
    const midi = getTrackMidi(@intCast(track)) orelse return 0;
    const note = midi.findNoteAt(beat, pitch) orelse return 0;
    return note.id;
}

/// Deselect all notes
pub export fn midi_clip_deselect_all(track: c_int) callconv(.c) void {
    const midi = getTrackMidi(@intCast(track)) orelse return;
    midi.deselectAll();
}

/// Select all notes
pub export fn midi_clip_select_all(track: c_int) callconv(.c) void {
    const midi = getTrackMidi(@intCast(track)) orelse return;
    midi.selectAll();
}

/// Set or clear the selected flag of one note by ID (selected != 0 selects).
/// Returns: 1 on success, 0 when the track or note does not exist
/// Control threads: serialised with other editors; republishes the playback snapshot
pub export fn midi_clip_set_note_selected(track: c_int, note_id: u32, selected: c_int) callconv(.c) c_int {
    const midi = getTrackMidi(@intCast(track)) orelse return 0;
    midi.edit_lock.lock();
    defer endEdit(midi);
    return if (midi.setSelected(note_id, selected != 0)) 1 else 0;
}

/// Get selected note count
pub export fn midi_clip_get_selected_count(track: c_int) callconv(.c) c_int {
    const midi = getTrackMidi(@intCast(track)) orelse return 0;
    return @intCast(midi.selectedCount());
}

/// Delete all selected notes
/// Control threads: serialised with other editors; republishes the playback snapshot
pub export fn midi_clip_delete_selected(track: c_int) callconv(.c) c_int {
    const midi = getTrackMidi(@intCast(track)) orelse return 0;
    midi.edit_lock.lock();
    defer endEdit(midi);
    return @intCast(midi.deleteSelected());
}

/// Move all selected notes
/// Control threads: serialised with other editors; republishes the playback snapshot
pub export fn midi_clip_move_selected(
    track: c_int,
    delta_beat: f64,
    delta_pitch: c_int,
) callconv(.c) void {
    const midi = getTrackMidi(@intCast(track)) orelse return;
    midi.edit_lock.lock();
    defer endEdit(midi);
    midi.moveSelected(delta_beat, delta_pitch);
}

/// Set velocity for all selected notes
/// Control threads: serialised with other editors; republishes the playback snapshot
pub export fn midi_clip_set_selected_velocity(
    track: c_int,
    velocity: u8,
) callconv(.c) void {
    const midi = getTrackMidi(@intCast(track)) orelse return;
    midi.edit_lock.lock();
    defer endEdit(midi);
    midi.setSelectedVelocity(velocity);
}

/// Quantize selected notes to grid
/// grid_beats: 0.25 = 16th, 0.5 = 8th, 1.0 = quarter, etc.
/// Control threads: serialised with other editors; republishes the playback snapshot
pub export fn midi_clip_quantize_selected(
    track: c_int,
    grid_beats: f64,
) callconv(.c) void {
    const midi = getTrackMidi(@intCast(track)) orelse return;
    midi.edit_lock.lock();
    defer endEdit(midi);
    midi.quantizeSelected(grid_beats);
}

/// Quantize all notes to grid
/// Control threads: serialised with other editors; republishes the playback snapshot
pub export fn midi_clip_quantize_all(
    track: c_int,
    grid_beats: f64,
) callconv(.c) void {
    const midi = getTrackMidi(@intCast(track)) orelse return;
    midi.edit_lock.lock();
    defer endEdit(midi);
    midi.quantizeAll(grid_beats);
}

/// Select notes in rectangle
/// Control threads: serialised with other editors; republishes the playback snapshot
pub export fn midi_clip_select_in_rect(
    track: c_int,
    beat_start: f64,
    beat_end: f64,
    pitch_low: u8,
    pitch_high: u8,
    add_to_selection: c_int,
) callconv(.c) void {
    const midi = getTrackMidi(@intCast(track)) orelse return;
    midi.edit_lock.lock();
    defer endEdit(midi);
    midi.selectInRect(beat_start, beat_end, pitch_low, pitch_high, add_to_selection != 0);
}

/// Clear all notes
/// Control threads: serialised with other editors; republishes the playback snapshot
pub export fn midi_clip_clear(track: c_int) callconv(.c) void {
    const midi = getTrackMidi(@intCast(track)) orelse return;
    midi.edit_lock.lock();
    defer endEdit(midi);
    midi.clear();
}

/// Get clip duration in beats (based on notes)
pub export fn midi_clip_get_duration(track: c_int) callconv(.c) f64 {
    const midi = getTrackMidi(@intCast(track)) orelse return 0.0;
    return midi.getDuration();
}

/// Set tempo for the clip (for time conversion)
pub export fn midi_clip_set_tempo(track: c_int, tempo: f64) callconv(.c) void {
    const midi = getOrCreateTrackMidi(@intCast(track)) orelse return;
    midi.tempo = @max(20.0, @min(300.0, tempo));
}

/// Get tempo
pub export fn midi_clip_get_tempo(track: c_int) callconv(.c) f64 {
    const midi = getTrackMidi(@intCast(track)) orelse return 120.0;
    return midi.tempo;
}

// =============================================================================
// Playback Support
// =============================================================================

/// Notes whose timeline start lies in [start_beat, end_beat), read from the published snapshot.
/// Fills up to `pitches.len` (and `velocities.len`) entries and returns the total count, which
/// can be larger. Lock-free and allocation-free: safe on the audio thread with `Reader.audio`.
pub fn notesStartingInRange(track: usize, reader: Reader, start_beat: f64, end_beat: f64, pitches: []u8, velocities: []u8) usize {
    const midi = getTrackMidi(track) orelse return 0;
    const snapshot = midi.acquire(reader) orelse return 0;
    defer midi.release(reader);
    var count: usize = 0;
    for (snapshot.notes) |note| {
        if (note.start_beat >= start_beat and note.start_beat < end_beat) {
            if (count < pitches.len and count < velocities.len) {
                pitches[count] = note.pitch;
                velocities[count] = note.velocity;
            }
            count += 1;
        }
    }
    return count;
}

/// Notes whose timeline end lies in [start_beat, end_beat), read from the published snapshot.
/// Same contract as `notesStartingInRange`.
pub fn notesEndingInRange(track: usize, reader: Reader, start_beat: f64, end_beat: f64, pitches: []u8) usize {
    const midi = getTrackMidi(track) orelse return 0;
    const snapshot = midi.acquire(reader) orelse return 0;
    defer midi.release(reader);
    var count: usize = 0;
    for (snapshot.notes) |note| {
        if (note.end_beat >= start_beat and note.end_beat < end_beat) {
            if (count < pitches.len) pitches[count] = note.pitch;
            count += 1;
        }
    }
    return count;
}

/// A clip note on or off at a frame inside one block.
pub const ClipEvent = struct {
    /// Offset from the first frame of the block.
    frame: u32,
    pitch: u8,
    velocity: u8,
    on: bool,
};

/// Timeline sample at which something at `beat` happens: the first sample at or after it.
/// Working in whole samples makes the result independent of how the timeline is cut into blocks.
fn sampleOfBeat(beat: f64, samples_per_beat: f64) u64 {
    const exact = @ceil(beat * samples_per_beat);
    if (!(exact > 0.0)) return 0; // negative, zero or NaN
    if (exact >= 0x1p63) return std.math.maxInt(u64);
    return @intFromFloat(exact);
}

/// Note ons and offs of `track` that fall in the block of `frames` frames starting at timeline
/// sample `start_sample`, each placed on its own frame. Fills `out` sorted by frame, note offs
/// before note ons on the same frame (so a note that ends where the same pitch starts again is
/// retriggered, not cut). Returns the number written; events beyond `out.len` are dropped.
/// Lock-free and allocation-free: safe on the audio thread with `Reader.audio`.
pub fn collectBlockEvents(track: usize, reader: Reader, start_sample: u64, frames: usize, samples_per_beat: f64, out: []ClipEvent) usize {
    const midi = getTrackMidi(track) orelse return 0;
    const snapshot = midi.acquire(reader) orelse return 0;
    defer midi.release(reader);
    const end_sample = start_sample + frames;
    var count: usize = 0;
    for (snapshot.notes) |note| {
        const on_sample = sampleOfBeat(note.start_beat, samples_per_beat);
        if (on_sample >= start_sample and on_sample < end_sample and count < out.len) {
            out[count] = .{ .frame = @intCast(on_sample - start_sample), .pitch = note.pitch, .velocity = note.velocity, .on = true };
            count += 1;
        }
        const off_sample = sampleOfBeat(note.end_beat, samples_per_beat);
        if (off_sample >= start_sample and off_sample < end_sample and count < out.len) {
            out[count] = .{ .frame = @intCast(off_sample - start_sample), .pitch = note.pitch, .velocity = 0, .on = false };
            count += 1;
        }
    }
    // Insertion sort: stable, no allocation, and blocks hold few events.
    var i: usize = 1;
    while (i < count) : (i += 1) {
        const event = out[i];
        var j = i;
        while (j > 0 and eventBefore(event, out[j - 1])) : (j -= 1) out[j] = out[j - 1];
        out[j] = event;
    }
    return count;
}

fn eventBefore(a: ClipEvent, b: ClipEvent) bool {
    if (a.frame != b.frame) return a.frame < b.frame;
    return !a.on and b.on;
}

/// Whether playback has any audible note on `track`. Lock-free.
pub fn hasPlaybackNotes(track: usize, reader: Reader) bool {
    const midi = getTrackMidi(track) orelse return false;
    return midi.playbackCount(reader) > 0;
}

fn clampedCount(max_notes: c_int) usize {
    return if (max_notes > 0) @intCast(max_notes) else 0;
}

/// Get notes starting in a beat range (for triggering note-on).
/// Notes are offset by the clip's start position in the timeline.
/// Returns count of notes found (may exceed max_notes), fills output arrays.
/// Lock-free: reads the published playback snapshot.
pub export fn midi_clip_get_notes_starting_in_range(
    track: c_int,
    start_beat: f64,
    end_beat: f64,
    out_pitches: ?[*]u8,
    out_velocities: ?[*]u8,
    max_notes: c_int,
) callconv(.c) c_int {
    const index = trackIndex(track) orelse return 0;
    const capacity = if (out_pitches != null and out_velocities != null) clampedCount(max_notes) else 0;
    const pitches: []u8 = if (out_pitches) |ptr| ptr[0..capacity] else &.{};
    const velocities: []u8 = if (out_velocities) |ptr| ptr[0..capacity] else &.{};
    const count = notesStartingInRange(index, .control, start_beat, end_beat, pitches, velocities);
    return @intCast(@min(count, std.math.maxInt(c_int)));
}

/// Get notes ending in a beat range (for triggering note-off).
/// Notes are offset by the clip's start position in the timeline.
/// Returns count of notes found (may exceed max_notes), fills output array.
/// Lock-free: reads the published playback snapshot.
pub export fn midi_clip_get_notes_ending_in_range(
    track: c_int,
    start_beat: f64,
    end_beat: f64,
    out_pitches: ?[*]u8,
    max_notes: c_int,
) callconv(.c) c_int {
    const index = trackIndex(track) orelse return 0;
    const capacity = if (out_pitches != null) clampedCount(max_notes) else 0;
    const pitches: []u8 = if (out_pitches) |ptr| ptr[0..capacity] else &.{};
    const count = notesEndingInRange(index, .control, start_beat, end_beat, pitches);
    return @intCast(@min(count, std.math.maxInt(c_int)));
}

/// Check if a track has any MIDI notes (muted ones included). Control threads.
pub export fn midi_clip_has_notes(track: c_int) callconv(.c) c_int {
    const midi = getTrackMidi(trackIndex(track) orelse return 0) orelse return 0;
    return if (midi.count() > 0) 1 else 0;
}

/// Get clip start position in timeline (beats)
pub export fn midi_clip_get_start_beat(track: c_int) callconv(.c) f64 {
    const midi = getTrackMidi(@intCast(track)) orelse return 0.0;
    return midi.clip_start_beat;
}

/// Set clip start position in timeline (beats)
/// Control threads: serialised with other editors; republishes the playback snapshot
pub export fn midi_clip_set_start_beat(track: c_int, start_beat: f64) callconv(.c) void {
    const midi = getOrCreateTrackMidi(@intCast(track)) orelse return;
    midi.edit_lock.lock();
    defer endEdit(midi);
    midi.clip_start_beat = @max(0.0, start_beat);
    log.info("Moved MIDI clip on track {} to beat {d:.2}", .{ track, midi.clip_start_beat });
}

/// Get clip duration (beats) - based on furthest note end
pub export fn midi_clip_get_clip_duration(track: c_int) callconv(.c) f64 {
    const midi = getTrackMidi(@intCast(track)) orelse return 0.0;
    return midi.getDuration();
}

/// Add demo notes for a track (called when piano roll opens with no notes)
/// Notes are relative to clip start (beat 0 = clip start)
/// Clip position is set based on track number for multi-track demos
/// Control threads: serialised with other editors; republishes the playback snapshot
pub export fn midi_clip_add_demo_notes(track: c_int) callconv(.c) void {
    const midi = getOrCreateTrackMidi(@intCast(track)) orelse return;

    midi.edit_lock.lock();
    defer endEdit(midi);

    // Only add demo notes if empty
    if (midi.count() > 0) return;

    // Set clip position based on track (4 beats per track for sequential playback)
    midi.clip_start_beat = @as(f64, @floatFromInt(track)) * 4.0;
    midi.clip_duration_beats = 4.0;

    // Simple C major chord progression: C - G - Am - F
    // Notes are RELATIVE to clip start (0 = start of clip)

    // Beat 0: C major (C4, E4, G4)
    _ = midi.addNote(.{ .start_beat = 0.0, .duration_beats = 1.0, .pitch = 60, .velocity = 100 }) catch {};
    _ = midi.addNote(.{ .start_beat = 0.0, .duration_beats = 1.0, .pitch = 64, .velocity = 90 }) catch {};
    _ = midi.addNote(.{ .start_beat = 0.0, .duration_beats = 1.0, .pitch = 67, .velocity = 85 }) catch {};

    // Beat 1: G major (G3, B3, D4)
    _ = midi.addNote(.{ .start_beat = 1.0, .duration_beats = 1.0, .pitch = 55, .velocity = 100 }) catch {};
    _ = midi.addNote(.{ .start_beat = 1.0, .duration_beats = 1.0, .pitch = 59, .velocity = 90 }) catch {};
    _ = midi.addNote(.{ .start_beat = 1.0, .duration_beats = 1.0, .pitch = 62, .velocity = 85 }) catch {};

    // Beat 2: A minor (A3, C4, E4)
    _ = midi.addNote(.{ .start_beat = 2.0, .duration_beats = 1.0, .pitch = 57, .velocity = 100 }) catch {};
    _ = midi.addNote(.{ .start_beat = 2.0, .duration_beats = 1.0, .pitch = 60, .velocity = 90 }) catch {};
    _ = midi.addNote(.{ .start_beat = 2.0, .duration_beats = 1.0, .pitch = 64, .velocity = 85 }) catch {};

    // Beat 3: F major (F3, A3, C4)
    _ = midi.addNote(.{ .start_beat = 3.0, .duration_beats = 1.0, .pitch = 53, .velocity = 100 }) catch {};
    _ = midi.addNote(.{ .start_beat = 3.0, .duration_beats = 1.0, .pitch = 57, .velocity = 90 }) catch {};
    _ = midi.addNote(.{ .start_beat = 3.0, .duration_beats = 1.0, .pitch = 60, .velocity = 85 }) catch {};

    log.info("Added demo MIDI clip to track {} at timeline position {d} beats", .{ track, midi.clip_start_beat });
}

// =============================================================================
// Serialization for Project Persistence
// =============================================================================

/// Serialize all MIDI notes for a track into a buffer
/// Format per note: start_beat(f64), duration(f64), pitch(u8), velocity(u8), muted(u8)
/// Returns bytes written, or -1 on error
pub export fn midi_clip_serialize(
    track: c_int,
    out_buffer: [*]u8,
    buffer_size: c_int,
) callconv(.c) c_int {
    const midi = getTrackMidi(@intCast(track)) orelse return 0;

    // Read-only: keep other editors out, nothing to republish.
    midi.edit_lock.lock();
    defer midi.edit_lock.unlock();

    const bytes_per_note: usize = 8 + 8 + 1 + 1 + 1; // 19 bytes per note
    const header_size: usize = 8 + 8; // clip_start_beat + clip_duration_beats

    const required_size = header_size + midi.notes.items.len * bytes_per_note;
    if (required_size > @as(usize, @intCast(buffer_size))) {
        return -1;
    }

    var pos: usize = 0;
    const buf = out_buffer[0..@intCast(buffer_size)];

    // Write header: clip position and duration
    @memcpy(buf[pos..][0..8], std.mem.asBytes(&midi.clip_start_beat));
    pos += 8;
    @memcpy(buf[pos..][0..8], std.mem.asBytes(&midi.clip_duration_beats));
    pos += 8;

    // Write each note
    for (midi.notes.items) |note| {
        @memcpy(buf[pos..][0..8], std.mem.asBytes(&note.start_beat));
        pos += 8;
        @memcpy(buf[pos..][0..8], std.mem.asBytes(&note.duration_beats));
        pos += 8;
        buf[pos] = note.pitch;
        pos += 1;
        buf[pos] = note.velocity;
        pos += 1;
        buf[pos] = if (note.muted) 1 else 0;
        pos += 1;
    }

    log.info("Serialized {} MIDI notes for track {} ({} bytes)", .{ midi.notes.items.len, track, pos });
    return @intCast(pos);
}

/// Deserialize MIDI notes from a buffer into a track
/// Clears existing notes first
/// Returns number of notes loaded, or -1 on error
pub export fn midi_clip_deserialize(
    track: c_int,
    in_buffer: [*]const u8,
    buffer_size: c_int,
) callconv(.c) c_int {
    const midi = getOrCreateTrackMidi(@intCast(track)) orelse return -1;

    midi.edit_lock.lock();
    defer endEdit(midi);

    const bytes_per_note: usize = 8 + 8 + 1 + 1 + 1; // 19 bytes per note
    const header_size: usize = 8 + 8;

    if (@as(usize, @intCast(buffer_size)) < header_size) {
        return -1;
    }

    // Clear existing notes
    midi.clear();

    const buf = in_buffer[0..@intCast(buffer_size)];
    var pos: usize = 0;

    // Read header
    midi.clip_start_beat = std.mem.bytesToValue(f64, buf[pos..][0..8]);
    pos += 8;
    midi.clip_duration_beats = std.mem.bytesToValue(f64, buf[pos..][0..8]);
    pos += 8;

    // Read notes
    var note_count: c_int = 0;
    while (pos + bytes_per_note <= @as(usize, @intCast(buffer_size))) {
        const start_beat = std.mem.bytesToValue(f64, buf[pos..][0..8]);
        pos += 8;
        const duration = std.mem.bytesToValue(f64, buf[pos..][0..8]);
        pos += 8;
        const pitch = buf[pos];
        pos += 1;
        const velocity = buf[pos];
        pos += 1;
        const muted = buf[pos] != 0;
        pos += 1;

        const note = MidiNote{
            .start_beat = start_beat,
            .duration_beats = duration,
            .pitch = pitch,
            .velocity = velocity,
            .muted = muted,
        };

        _ = midi.addNote(note) catch continue;
        note_count += 1;
    }

    log.info("Deserialized {} MIDI notes for track {} (clip at beat {d:.2})", .{ note_count, track, midi.clip_start_beat });
    return note_count;
}

/// Get the size needed to serialize MIDI notes for a track
pub export fn midi_clip_get_serialize_size(track: c_int) callconv(.c) c_int {
    const midi = getTrackMidi(@intCast(track)) orelse return 0;

    const bytes_per_note: usize = 8 + 8 + 1 + 1 + 1; // 19 bytes
    const header_size: usize = 8 + 8; // 16 bytes

    return @intCast(header_size + midi.notes.items.len * bytes_per_note);
}

// =============================================================================
// Tests
// =============================================================================

test "midi note list basic operations" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var list = MidiNoteList.init(allocator);
    defer list.deinit();

    // Add notes
    const id1 = try list.addNote(.{ .start_beat = 0.0, .duration_beats = 1.0, .pitch = 60 });
    const id2 = try list.addNote(.{ .start_beat = 1.0, .duration_beats = 0.5, .pitch = 64 });

    try testing.expectEqual(@as(usize, 2), list.count());

    // Get note
    const note1 = list.getNote(id1);
    try testing.expect(note1 != null);
    try testing.expectEqual(@as(u8, 60), note1.?.pitch);

    // Move note
    try testing.expect(list.moveNote(id1, 2.0, 72));
    try testing.expectApproxEqAbs(@as(f64, 2.0), note1.?.start_beat, 0.001);
    try testing.expectEqual(@as(u8, 72), note1.?.pitch);

    // Remove note
    try testing.expect(list.removeNote(id2));
    try testing.expectEqual(@as(usize, 1), list.count());
}

test "midi note list selection" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var list = MidiNoteList.init(allocator);
    defer list.deinit();

    const id1 = try list.addNote(.{ .start_beat = 0.0, .pitch = 60 });
    const id2 = try list.addNote(.{ .start_beat = 1.0, .pitch = 64 });
    _ = try list.addNote(.{ .start_beat = 2.0, .pitch = 67 });

    // Select one
    try testing.expect(list.setSelected(id1, true));
    try testing.expectEqual(@as(usize, 1), list.selectedCount());

    // Select all
    list.selectAll();
    try testing.expectEqual(@as(usize, 3), list.selectedCount());

    // Deselect all
    list.deselectAll();
    try testing.expectEqual(@as(usize, 0), list.selectedCount());

    // Select in rect
    _ = list.setSelected(id1, false);
    _ = list.setSelected(id2, false);
    list.selectInRect(0.5, 1.5, 60, 70, false);
    try testing.expectEqual(@as(usize, 1), list.selectedCount());
}

test "midi note list quantize" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var list = MidiNoteList.init(allocator);
    defer list.deinit();

    const id1 = try list.addNote(.{ .start_beat = 0.13, .duration_beats = 0.47, .pitch = 60, .selected = true });

    list.quantizeSelected(0.25); // 16th note grid

    const note = list.getNote(id1);
    try testing.expect(note != null);
    try testing.expectApproxEqAbs(@as(f64, 0.25), note.?.start_beat, 0.001); // 0.13 is nearer 0.25 than 0
    try testing.expectApproxEqAbs(@as(f64, 0.5), note.?.duration_beats, 0.001); // Rounds to 0.5
}

test "midi note containment" {
    const testing = std.testing;

    const note = MidiNote{
        .start_beat = 1.0,
        .duration_beats = 2.0,
        .pitch = 64,
    };

    // Contains point tests
    try testing.expect(note.containsPoint(1.5, 64));
    try testing.expect(note.containsPoint(1.0, 64));
    try testing.expect(!note.containsPoint(3.0, 64)); // At end (exclusive)
    try testing.expect(!note.containsPoint(1.5, 65)); // Wrong pitch

    // Overlap tests
    try testing.expect(note.overlapsRange(0.5, 1.5));
    try testing.expect(note.overlapsRange(2.5, 3.5));
    try testing.expect(note.overlapsRange(1.5, 2.5));
    try testing.expect(!note.overlapsRange(3.5, 4.5)); // After
    try testing.expect(!note.overlapsRange(0.0, 0.5)); // Before
}

test "midi clip: playback queries never miss a note while another thread edits the clip" {
    const testing = std.testing;
    const track: c_int = 14;
    midi_clip_clear(track);
    defer midi_clip_clear(track);
    try testing.expect(midi_clip_add_note(track, 0.5, 0.25, 60, 100) != 0);
    const moving = midi_clip_add_note(track, 2.0, 0.25, 64, 100);
    try testing.expect(moving != 0);

    const Editor = struct {
        fn run(stop: *std.atomic.Value(bool)) void {
            var i: usize = 0;
            while (!stop.load(.acquire)) : (i += 1) {
                const beat: f64 = 2.0 + @as(f64, @floatFromInt(i % 8)) * 0.125;
                _ = midi_clip_move_note(track, moving_id.load(.acquire), beat, 64);
            }
        }
        var moving_id: std.atomic.Value(u32) = .init(0);
    };
    Editor.moving_id.store(moving, .release);
    var stop: std.atomic.Value(bool) = .init(false);
    const thread = try std.Thread.spawn(.{}, Editor.run, .{&stop});
    defer thread.join();
    defer stop.store(true, .release);

    var missed: usize = 0;
    for (0..200_000) |_| {
        var pitches: [4]u8 = undefined;
        var velocities: [4]u8 = undefined;
        const starting = midi_clip_get_notes_starting_in_range(track, 0.0, 1.0, &pitches, &velocities, 4);
        var ending: [4]u8 = undefined;
        const ended = midi_clip_get_notes_ending_in_range(track, 0.5, 1.0, &ending, 4);
        if (starting != 1 or ended != 1) missed += 1;
    }
    try testing.expectEqual(@as(usize, 0), missed);
}

test "midi clip: published snapshot has timeline positions, skips muted notes, and frees old copies" {
    const testing = std.testing;
    var list = MidiNoteList.init(testing.allocator);
    defer list.deinit();
    try testing.expect(list.acquire(.audio) == null);
    list.release(.audio);

    list.clip_start_beat = 8.0;
    _ = try list.addNote(.{ .start_beat = 1.0, .duration_beats = 0.5, .pitch = 60, .velocity = 90 });
    _ = try list.addNote(.{ .start_beat = 2.0, .duration_beats = 1.0, .pitch = 62, .muted = true });
    try list.publish();

    const first = list.acquire(.audio).?;
    try testing.expectEqual(@as(usize, 1), first.notes.len);
    try testing.expectEqual(@as(f64, 9.0), first.notes[0].start_beat);
    try testing.expectEqual(@as(f64, 9.5), first.notes[0].end_beat);
    try testing.expectEqual(@as(u8, 90), first.notes[0].velocity);
    list.release(.audio);

    // Edits stay invisible to playback until published; publishing again frees the old copy
    // (the testing allocator reports a leak otherwise).
    list.clear();
    try testing.expectEqual(@as(usize, 1), list.playbackCount(.offline));
    try list.publish();
    try testing.expectEqual(@as(usize, 0), list.playbackCount(.offline));
}

test "midi clip: playback range queries see edits made through the C API" {
    const testing = std.testing;
    const track: c_int = 13;
    midi_clip_clear(track);
    defer midi_clip_clear(track);
    try testing.expect(!hasPlaybackNotes(13, .audio));
    const id = midi_clip_add_note(track, 1.0, 1.0, 67, 80);
    try testing.expect(id != 0);
    midi_clip_set_start_beat(track, 4.0);
    try testing.expect(hasPlaybackNotes(13, .audio));

    var pitches: [2]u8 = undefined;
    var velocities: [2]u8 = undefined;
    try testing.expectEqual(@as(usize, 1), notesStartingInRange(13, .audio, 5.0, 5.5, &pitches, &velocities));
    try testing.expectEqual(@as(u8, 67), pitches[0]);
    try testing.expectEqual(@as(usize, 1), notesEndingInRange(13, .audio, 6.0, 6.5, &pitches));
    try testing.expectEqual(@as(usize, 0), notesStartingInRange(13, .audio, 1.0, 2.0, &pitches, &velocities));

    try testing.expectEqual(@as(c_int, 1), midi_clip_move_note(track, id, 0.0, 67));
    try testing.expectEqual(@as(usize, 1), notesStartingInRange(13, .audio, 4.0, 4.5, &pitches, &velocities));
    // Out-of-range tracks answer zero instead of trapping.
    try testing.expectEqual(@as(c_int, 0), midi_clip_get_notes_starting_in_range(-1, 0.0, 1.0, null, null, 0));
    try testing.expectEqual(@as(c_int, 0), midi_clip_get_notes_ending_in_range(99, 0.0, 1.0, null, 0));
}

test "midi clip: block events land on their own frame, offs before ons, independent of block cuts" {
    const testing = std.testing;
    const track: c_int = 12;
    midi_clip_clear(track);
    defer midi_clip_clear(track);
    midi_clip_set_start_beat(track, 0.0);
    // 24000 samples per beat. Note A: 3000..9000. Note B (same pitch) starts where A ends.
    try testing.expect(midi_clip_add_note(track, 0.125, 0.25, 60, 100) != 0);
    try testing.expect(midi_clip_add_note(track, 0.375, 0.25, 60, 80) != 0);

    var events: [8]ClipEvent = undefined;
    var n = collectBlockEvents(12, .audio, 8960, 64, 24000.0, &events);
    try testing.expectEqual(@as(usize, 2), n);
    try testing.expectEqual(ClipEvent{ .frame = 40, .pitch = 60, .velocity = 0, .on = false }, events[0]);
    try testing.expectEqual(ClipEvent{ .frame = 40, .pitch = 60, .velocity = 80, .on = true }, events[1]);

    // Every event appears exactly once however the timeline is cut.
    for ([_]usize{ 1, 7, 64, 1000, 4096 }) |block| {
        var seen: usize = 0;
        var start: u64 = 0;
        while (start < 20000) : (start += block) {
            n = collectBlockEvents(12, .audio, start, block, 24000.0, &events);
            for (events[0..n]) |e| {
                const at = start + e.frame;
                try testing.expect(at == 3000 or at == 9000 or at == 15000);
            }
            seen += n;
        }
        try testing.expectEqual(@as(usize, 4), seen);
    }

    // A full output keeps the earliest events and drops the rest.
    n = collectBlockEvents(12, .audio, 0, 20000, 24000.0, events[0..1]);
    try testing.expectEqual(@as(usize, 1), n);
    try testing.expectEqual(@as(usize, 0), collectBlockEvents(99, .audio, 0, 20000, 24000.0, &events));
}
