//! Limits of the control protocol shared by the `seridian` CLI and the app's command socket, so the two
//! sides check the same range and give the same message. Imports nothing but `std`.

const std = @import("std");

/// Largest note start, note length and automation beat, in beats.
pub const max_beats: f64 = 1_000_000;

/// Message for a note start outside 0..max_beats.
pub const start_message = std.fmt.comptimePrint("start must be a number of beats 0..{d}", .{@as(u32, max_beats)});

/// Message for a note length outside (0, max_beats].
pub const length_message = std.fmt.comptimePrint("length must be a number of beats above 0 and up to {d}", .{@as(u32, max_beats)});

test "limits render as whole numbers" {
    try std.testing.expectEqualStrings("start must be a number of beats 0..1000000", start_message);
}
