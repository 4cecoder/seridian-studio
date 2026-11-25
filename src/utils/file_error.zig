//! Plain-words causes for failed file operations (save, open, export), kept in one place so the control
//! socket can say why a command failed instead of only that it did.

const std = @import("std");

/// Longest cause text kept by `record`.
pub const capacity = 96;

var last_text: [capacity:0]u8 = @splat(0);

/// A short lower-case cause for `err` ("permission denied", "no such file or directory", ...).
/// Errors without a known wording are rendered into `buf` as "unexpected error (Name)".
pub fn describe(buf: []u8, err: anyerror) []const u8 {
    return switch (err) {
        error.AccessDenied, error.PermissionDenied => "permission denied",
        error.FileNotFound => "no such file or directory",
        error.NotDir => "not a directory",
        error.IsDir => "is a directory",
        error.NoSpaceLeft => "no space left on the device",
        error.ReadOnlyFileSystem => "read-only file system",
        error.NameTooLong => "file name too long",
        error.PathAlreadyExists => "already exists",
        error.ProjectNotFound => "no project.daw in that folder",
        error.DiskQuota => "disk quota exceeded",
        error.FileBusy => "file is busy",
        error.SymLinkLoop => "too many symbolic links",
        error.BadPathName, error.InvalidUtf8 => "invalid path",
        else => std.fmt.bufPrint(buf, "unexpected error ({s})", .{@errorName(err)}) catch "unexpected error",
    };
}

/// Remembers the cause of the most recent failure for `lastCause`.
pub fn record(err: anyerror) void {
    var buf: [capacity]u8 = undefined;
    const text = describe(&buf, err);
    const n = @min(text.len, capacity);
    @memcpy(last_text[0..n], text[0..n]);
    last_text[n] = 0;
}

/// The cause recorded by the last `record`, or "" before any failure. NUL-terminated.
pub fn lastCause() [*:0]const u8 {
    return &last_text;
}

test "describe: common causes in plain words" {
    var buf: [capacity]u8 = undefined;
    const cases = [_]struct { err: anyerror, text: []const u8 }{
        .{ .err = error.AccessDenied, .text = "permission denied" },
        .{ .err = error.PermissionDenied, .text = "permission denied" },
        .{ .err = error.FileNotFound, .text = "no such file or directory" },
        .{ .err = error.NotDir, .text = "not a directory" },
        .{ .err = error.IsDir, .text = "is a directory" },
        .{ .err = error.NoSpaceLeft, .text = "no space left on the device" },
        .{ .err = error.ReadOnlyFileSystem, .text = "read-only file system" },
        .{ .err = error.NameTooLong, .text = "file name too long" },
        .{ .err = error.PathAlreadyExists, .text = "already exists" },
        .{ .err = error.ProjectNotFound, .text = "no project.daw in that folder" },
        .{ .err = error.DiskQuota, .text = "disk quota exceeded" },
    };
    for (cases) |case| try std.testing.expectEqualStrings(case.text, describe(&buf, case.err));
    try std.testing.expectEqualStrings("unexpected error (Unheard)", describe(&buf, error.Unheard));
}

test "record keeps the last cause and lastCause reads it back" {
    record(error.NotDir);
    try std.testing.expectEqualStrings("not a directory", std.mem.span(lastCause()));
    record(error.AccessDenied);
    try std.testing.expectEqualStrings("permission denied", std.mem.span(lastCause()));
}
