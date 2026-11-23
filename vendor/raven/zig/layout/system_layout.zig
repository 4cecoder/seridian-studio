// Seridian: the Zig side of layout/system_layout.c. Prints the layout of the std.c types that Raven's Zig code
// passes to the C library, in the same lines as the C program prints the system headers' ones (check.sh step 3b).
const std = @import("std");
const c = std.c;

fn typeLine(w: *std.Io.Writer, comptime name: []const u8, comptime T: type) !void {
    try w.print("sizeof " ++ name ++ " {d}\nalignof " ++ name ++ " {d}\n", .{ @sizeOf(T), @alignOf(T) });
}

fn fieldLine(w: *std.Io.Writer, comptime name: []const u8, comptime T: type, comptime field: []const u8) !void {
    try w.print("offsetof " ++ name ++ "." ++ field ++ " {d}\n", .{@offsetOf(T, field)});
}

pub fn main() !void {
    var buf: [1024]u8 = undefined;
    var out = std.Io.File.stdout().writer(std.Io.Threaded.global_single_threaded.io(), &buf);
    const w = &out.interface;
    try typeLine(w, "pthread_t", c.pthread_t);
    try typeLine(w, "pthread_mutex_t", c.pthread_mutex_t);
    try typeLine(w, "pthread_cond_t", c.pthread_cond_t);
    try typeLine(w, "pthread_rwlock_t", c.pthread_rwlock_t);
    try typeLine(w, "time_t", c.time_t);
    try typeLine(w, "struct timespec", c.timespec);
    try fieldLine(w, "struct timespec", c.timespec, "sec");
    try fieldLine(w, "struct timespec", c.timespec, "nsec");
    try typeLine(w, "struct pollfd", c.pollfd);
    try fieldLine(w, "struct pollfd", c.pollfd, "fd");
    try fieldLine(w, "struct pollfd", c.pollfd, "events");
    try fieldLine(w, "struct pollfd", c.pollfd, "revents");
    try fieldLine(w, "struct dirent", c.dirent, "name");
    try w.print("sizeof dirent.name {d}\n", .{@sizeOf(@FieldType(c.dirent, "name"))});
    try w.flush();
}
