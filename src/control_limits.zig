//! Limits of the control protocol shared by the `seridian` CLI and the app's command socket, so the two
//! sides check the same range and give the same message. Imports nothing but `std`.

const std = @import("std");

/// Largest note start, note length and automation beat, in beats.
pub const max_beats: f64 = 1_000_000;

/// Message for a note start outside 0..max_beats.
pub const start_message = std.fmt.comptimePrint("start must be a number of beats 0..{d}", .{@as(u32, max_beats)});

/// Message for a note length outside (0, max_beats].
pub const length_message = std.fmt.comptimePrint("length must be a number of beats above 0 and up to {d}", .{@as(u32, max_beats)});

/// Longest track name, in bytes (printable ASCII, so also in characters).
pub const max_track_name: usize = 24;

/// Most words a track name may have on the wire (a command line holds 8 words; `set N name` uses 3).
pub const max_track_name_words: usize = 5;

/// Message for a track name that is empty, too long or not printable.
pub const name_message = std.fmt.comptimePrint("name must be 1 to {d} printable characters (letters, digits, punctuation, spaces) in at most {d} words", .{ max_track_name, max_track_name_words });

/// True when `text` is a usable track name: 1 to `max_track_name` bytes, each printable ASCII (0x20..0x7e),
/// not starting or ending with a space, with no run of spaces. The wire form joins words with one space.
pub fn isValidTrackName(text: []const u8) bool {
    if (text.len == 0 or text.len > max_track_name) return false;
    if (text[0] == ' ' or text[text.len - 1] == ' ') return false;
    var words: usize = 1;
    for (text, 0..) |c, i| {
        if (c < 0x20 or c > 0x7e) return false;
        if (c == ' ') {
            if (text[i - 1] == ' ') return false;
            words += 1;
        }
    }
    return words <= max_track_name_words;
}

test "track names" {
    try std.testing.expect(isValidTrackName("Bass"));
    try std.testing.expect(isValidTrackName("Lead Synth 2"));
    const long: [25]u8 = @splat('a');
    try std.testing.expect(isValidTrackName(long[0..24]));
    try std.testing.expect(!isValidTrackName(&long));
    try std.testing.expect(!isValidTrackName(""));
    try std.testing.expect(!isValidTrackName(" Bass"));
    try std.testing.expect(!isValidTrackName("Bass "));
    try std.testing.expect(!isValidTrackName("Big  Bass"));
    try std.testing.expect(!isValidTrackName("Ba\tss"));
    try std.testing.expect(!isValidTrackName("Ba\x01ss"));
    try std.testing.expect(!isValidTrackName("Ba\x7fss"));
    try std.testing.expect(!isValidTrackName("Bass\n"));
    try std.testing.expect(!isValidTrackName("Bj\xc3\xb6rn"));
    try std.testing.expect(isValidTrackName("a b c d e"));
    try std.testing.expect(!isValidTrackName("a b c d e f"));
}

test "limits render as whole numbers" {
    try std.testing.expectEqualStrings("start must be a number of beats 0..1000000", start_message);
}
