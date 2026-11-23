// Translated to Zig from soundcraft/crates/midi/src/lib.rs (Copyright (c) 2026 ArtCraft Team and the SoundCraft contributors, MIT OR Apache-2.0). Modified by Seridian.
//! MIDI sequence model: the content of a region or track, in ticks at `PPQ` (960) ticks
//! per quarter note, plus the deterministic PRNG and General MIDI display names.
//!
//! This is the namespace file for the `midi` directory. It re-exports the types and
//! functions of the sibling files under their Rust names. The Standard MIDI File reader
//! and the editing operations (`smf`, `ops`) are not yet translated and are not listed.

const std = @import("std");

pub const names = @import("names.zig");
pub const rng = @import("rng.zig");
pub const sequence = @import("sequence.zig");
pub const smf = @import("smf.zig");
pub const ops = @import("ops.zig");

/// Ticks per quarter note used throughout the model.
pub const PPQ: u32 = 960;

/// Errors from reading or writing MIDI data.
///
/// The Rust enum carries payloads (byte offsets, lengths, limits, reason strings). An
/// error set cannot carry them, so those details are dropped here. See the translation
/// notes for the planned diagnostic out-parameter.
pub const MidiError = error{
    /// Not a Standard MIDI File (missing MThd header).
    NotSmf,
    /// Unexpected end of data.
    Truncated,
    /// Variable-length quantity longer than 4 bytes.
    VlqTooLong,
    /// A chunk length exceeds the remaining data.
    BadChunkLength,
    /// Invalid MIDI data.
    Invalid,
    /// Unsupported MIDI file feature.
    Unsupported,
    /// Too many events (limit in `smf`).
    TooManyEvents,
    /// Too many tracks (limit in `smf`).
    TooManyTracks,
    /// Writing a MIDI file failed.
    Write,
};

pub const Note = sequence.Note;
pub const CtrlKind = sequence.CtrlKind;
pub const CtrlEvent = sequence.CtrlEvent;
pub const Sequence = sequence.Sequence;
pub const NotesIn = sequence.NotesIn;
pub const NotesOverlapping = sequence.NotesOverlapping;

pub const XorShift = rng.XorShift;

pub const NoteName = names.NoteName;
pub const noteName = names.noteName;
pub const gmDrumName = names.gmDrumName;
pub const gmProgramName = names.gmProgramName;

test {
    std.testing.refAllDecls(@This());
}

test "PPQ is 960 ticks per quarter note" {
    try std.testing.expectEqual(@as(u32, 960), PPQ);
}

test "re-exports point at the sibling files" {
    var s: Sequence = .{};
    defer s.deinit(std.testing.allocator);
    try s.notes.append(std.testing.allocator, .{ .pitch = 60, .velocity = 100, .release_velocity = 64, .channel = 0, .start = 0, .length = 960 });
    try std.testing.expectEqual(@as(i64, 960), s.endTick());
    try std.testing.expectEqualStrings("C3", noteName(60).slice());
    var rnd = XorShift.init(1);
    try std.testing.expectEqual(@as(u64, 5180492295206395165), rnd.nextU64());
}
