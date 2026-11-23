//! Ableton-style keymap: one table of (key, modifiers, action), a lookup, a
//! letter-key to MIDI pitch helper, and a small bounded undo stack.
//! "Cmd" means Ctrl on Linux/Windows and Super on macOS; the table uses one
//! `cmd` flag and lookup accepts either.
//! Pure logic: no allocation, no globals, no UI dependencies.

const std = @import("std");
const testing = std.testing;
const piano_math = @import("piano_math.zig");

/// RKey codes from vendor/raven/include/raven/raven_window.h.
pub const key_space: i32 = 32;
pub const key_minus: i32 = 45;
pub const key_0: i32 = 48;
pub const key_equal: i32 = 61;
pub const key_a: i32 = 65;
pub const key_enter: i32 = 257;
pub const key_backspace: i32 = 259;
pub const key_delete: i32 = 261;

/// RModifier bits; Ctrl/Alt/Super are shared with piano_math.
pub const modifier_shift: u32 = 1 << 0;

pub const Action = enum {
    none,
    play_stop,
    stop_and_rewind,
    undo,
    redo,
    select_all,
    copy,
    cut,
    paste,
    duplicate,
    delete,
    split_at_playhead,
    file_new,
    file_open,
    file_save,
    file_save_as,
    view_arrangement,
    view_piano_roll,
    zoom_in,
    zoom_out,
    popout_piano_roll,
    popout_mixer,
};

pub const Binding = struct {
    key: i32,
    /// Ctrl (Linux) or Super (macOS) must be held.
    cmd: bool,
    shift: bool,
    action: Action,
};

/// The single keymap table.
pub const bindings = [_]Binding{
    .{ .key = key_space, .cmd = false, .shift = false, .action = .play_stop },
    .{ .key = key_enter, .cmd = false, .shift = false, .action = .stop_and_rewind },
    .{ .key = 'Z', .cmd = true, .shift = false, .action = .undo },
    .{ .key = 'Z', .cmd = true, .shift = true, .action = .redo },
    .{ .key = 'A', .cmd = true, .shift = false, .action = .select_all },
    .{ .key = 'C', .cmd = true, .shift = false, .action = .copy },
    .{ .key = 'X', .cmd = true, .shift = false, .action = .cut },
    .{ .key = 'V', .cmd = true, .shift = false, .action = .paste },
    .{ .key = 'D', .cmd = true, .shift = false, .action = .duplicate },
    .{ .key = key_delete, .cmd = false, .shift = false, .action = .delete },
    .{ .key = key_backspace, .cmd = false, .shift = false, .action = .delete },
    .{ .key = 'E', .cmd = true, .shift = false, .action = .split_at_playhead },
    .{ .key = 'N', .cmd = true, .shift = false, .action = .file_new },
    .{ .key = 'O', .cmd = true, .shift = false, .action = .file_open },
    .{ .key = 'S', .cmd = true, .shift = false, .action = .file_save },
    .{ .key = 'S', .cmd = true, .shift = true, .action = .file_save_as },
    .{ .key = key_0 + 1, .cmd = true, .shift = false, .action = .view_arrangement },
    .{ .key = key_0 + 2, .cmd = true, .shift = false, .action = .view_piano_roll },
    .{ .key = key_equal, .cmd = true, .shift = false, .action = .zoom_in },
    .{ .key = key_minus, .cmd = true, .shift = false, .action = .zoom_out },
    .{ .key = 'P', .cmd = true, .shift = true, .action = .popout_piano_roll },
    .{ .key = 'M', .cmd = true, .shift = true, .action = .popout_mixer },
    // Plain keys kept from the original transport and timeline shortcuts.
    .{ .key = 'S', .cmd = false, .shift = false, .action = .split_at_playhead },
    .{ .key = key_equal, .cmd = false, .shift = false, .action = .zoom_in },
    .{ .key = key_minus, .cmd = false, .shift = false, .action = .zoom_out },
};

/// Action bound to `key` (RKey code) with `modifiers` (RModifier bits), or .none.
/// Alt held never matches.
pub fn lookup(key: i32, modifiers: u32) Action {
    if ((modifiers & piano_math.modifier_alt) != 0) return .none;
    const cmd_held = (modifiers & (piano_math.modifier_ctrl | piano_math.modifier_super)) != 0;
    const shift_held = (modifiers & modifier_shift) != 0;
    for (bindings) |b| {
        if (b.key == key and b.cmd == cmd_held and b.shift == shift_held) return b.action;
    }
    return .none;
}

/// C ABI for the window (app/externs.zig). Returns the Action tag as an int; the
/// SERIDIAN_ACTION_* constants in app/externs.zig list the tags in the same order (tested there).
pub export fn seridian_keymap_lookup(key: i32, modifiers: u32) callconv(.c) c_int {
    return @intCast(@backingInt(lookup(key, modifiers)));
}

/// MIDI pitch for an RKey letter code (A..Z, ';' is 59) played from `octave_base`,
/// or -1 when the key is unmapped or the pitch leaves 0..127. Reuses piano_math.keyOffset.
pub fn keyToPitch(key: i32, octave_base: i32) i32 {
    // RKey letter codes are upper-case ASCII; piano_math maps lower-case keys.
    const normalized: i32 = if (key >= 'A' and key <= 'Z') key + ('a' - 'A') else key;
    return piano_math.keyToPitch(normalized, octave_base);
}

/// Bounded undo/redo history of `T`. `push` records a done action and clears
/// redo; at capacity the oldest entry is dropped. `undo` returns the entry to
/// reverse, `redo` the entry to re-apply.
pub fn UndoStack(comptime T: type, comptime capacity: usize) type {
    return struct {
        const Self = @This();
        undo_items: [capacity]T = undefined,
        undo_len: usize = 0,
        redo_items: [capacity]T = undefined,
        redo_len: usize = 0,

        /// Records a done action and clears redo. Drops the oldest entry at capacity.
        pub fn push(self: *Self, item: T) void {
            self.redo_len = 0;
            if (capacity == 0) return;
            if (self.undo_len == capacity) {
                std.mem.copyForwards(T, self.undo_items[0 .. capacity - 1], self.undo_items[1..capacity]);
                self.undo_len -= 1;
            }
            self.undo_items[self.undo_len] = item;
            self.undo_len += 1;
        }
        /// Pops the newest undo entry onto redo and returns it, or null when empty.
        pub fn undo(self: *Self) ?T {
            if (self.undo_len == 0) return null;
            self.undo_len -= 1;
            const item = self.undo_items[self.undo_len];
            self.redo_items[self.redo_len] = item;
            self.redo_len += 1;
            return item;
        }
        /// Pops the newest redo entry back onto undo and returns it, or null when empty.
        pub fn redo(self: *Self) ?T {
            if (self.redo_len == 0) return null;
            self.redo_len -= 1;
            const item = self.redo_items[self.redo_len];
            self.undo_items[self.undo_len] = item;
            self.undo_len += 1;
            return item;
        }
        pub fn canUndo(self: *const Self) bool {
            return self.undo_len > 0;
        }
        pub fn canRedo(self: *const Self) bool {
            return self.redo_len > 0;
        }
    };
}

// ---- tests ----

test "lookup: transport" {
    try testing.expectEqual(Action.play_stop, lookup(key_space, 0));
    try testing.expectEqual(Action.stop_and_rewind, lookup(key_enter, 0));
}

test "lookup: undo and redo with Ctrl or Super" {
    try testing.expectEqual(Action.undo, lookup('Z', piano_math.modifier_ctrl));
    try testing.expectEqual(Action.undo, lookup('Z', piano_math.modifier_super));
    try testing.expectEqual(Action.redo, lookup('Z', piano_math.modifier_ctrl | modifier_shift));
    try testing.expectEqual(Action.redo, lookup('Z', piano_math.modifier_super | modifier_shift));
}

test "lookup: edit keys" {
    const c = piano_math.modifier_ctrl;
    try testing.expectEqual(Action.select_all, lookup('A', c));
    try testing.expectEqual(Action.copy, lookup('C', c));
    try testing.expectEqual(Action.cut, lookup('X', c));
    try testing.expectEqual(Action.paste, lookup('V', c));
    try testing.expectEqual(Action.duplicate, lookup('D', c));
    try testing.expectEqual(Action.split_at_playhead, lookup('E', c));
    try testing.expectEqual(Action.delete, lookup(key_delete, 0));
    try testing.expectEqual(Action.delete, lookup(key_backspace, 0));
}

test "lookup: file and view and zoom" {
    const c = piano_math.modifier_super;
    try testing.expectEqual(Action.file_new, lookup('N', c));
    try testing.expectEqual(Action.file_open, lookup('O', c));
    try testing.expectEqual(Action.file_save, lookup('S', c));
    try testing.expectEqual(Action.file_save_as, lookup('S', c | modifier_shift));
    try testing.expectEqual(Action.view_arrangement, lookup('1', c));
    try testing.expectEqual(Action.view_piano_roll, lookup('2', c));
    try testing.expectEqual(Action.zoom_in, lookup(key_equal, c));
    try testing.expectEqual(Action.zoom_out, lookup(key_minus, c));
}

test "lookup: piano roll popout" {
    try testing.expectEqual(Action.popout_piano_roll, lookup('P', piano_math.modifier_ctrl | modifier_shift));
    try testing.expectEqual(Action.none, lookup('P', piano_math.modifier_ctrl));
}

test "lookup: mixer popout" {
    try testing.expectEqual(Action.popout_mixer, lookup('M', piano_math.modifier_ctrl | modifier_shift));
    try testing.expectEqual(Action.none, lookup('M', piano_math.modifier_ctrl));
    try testing.expectEqual(Action.none, lookup('M', modifier_shift));
}

test "lookup: unbound, missing Cmd, and Alt give none" {
    try testing.expectEqual(Action.none, lookup('Z', 0));
    try testing.expectEqual(Action.none, lookup('A', 0));
    try testing.expectEqual(Action.none, lookup('Q', piano_math.modifier_ctrl));
    try testing.expectEqual(Action.none, lookup('Z', piano_math.modifier_ctrl | piano_math.modifier_alt));
    try testing.expectEqual(Action.none, lookup(key_space, piano_math.modifier_ctrl));
    try testing.expectEqual(Action.none, lookup(-1, 0));
}

test "bindings table has no duplicate (key, cmd, shift)" {
    for (bindings, 0..) |a, i| {
        for (bindings[i + 1 ..]) |b| {
            try testing.expect(!(a.key == b.key and a.cmd == b.cmd and a.shift == b.shift));
        }
    }
}

test "keyToPitch: letters map relative to the octave base" {
    try testing.expectEqual(@as(i32, 60), keyToPitch('A', 60));
    try testing.expectEqual(@as(i32, 67), keyToPitch('G', 60));
    try testing.expectEqual(@as(i32, 61), keyToPitch('W', 60));
    try testing.expectEqual(@as(i32, 76), keyToPitch(';', 60));
    try testing.expectEqual(@as(i32, 72), keyToPitch('K', 60));
}

test "keyToPitch: unmapped and out of range give -1" {
    try testing.expectEqual(@as(i32, -1), keyToPitch('Z', 60));
    try testing.expectEqual(@as(i32, -1), keyToPitch(key_space, 60));
    try testing.expectEqual(@as(i32, -1), keyToPitch(';', 120));
    try testing.expectEqual(@as(i32, -1), keyToPitch('A', -1));
}

test "UndoStack: undo after push" {
    var s = UndoStack(u32, 4){};
    s.push(1);
    s.push(2);
    try testing.expect(s.canUndo());
    try testing.expectEqual(@as(?u32, 2), s.undo());
    try testing.expectEqual(@as(?u32, 1), s.undo());
    try testing.expectEqual(@as(?u32, null), s.undo());
    try testing.expect(!s.canUndo());
}

test "UndoStack: redo after undo" {
    var s = UndoStack(u32, 4){};
    s.push(1);
    s.push(2);
    _ = s.undo();
    try testing.expect(s.canRedo());
    try testing.expectEqual(@as(?u32, 2), s.redo());
    try testing.expectEqual(@as(?u32, null), s.redo());
    try testing.expect(s.canUndo());
}

test "UndoStack: push clears redo" {
    var s = UndoStack(u32, 4){};
    s.push(1);
    s.push(2);
    _ = s.undo();
    s.push(3);
    try testing.expect(!s.canRedo());
    try testing.expectEqual(@as(?u32, null), s.redo());
    try testing.expectEqual(@as(?u32, 3), s.undo());
    try testing.expectEqual(@as(?u32, 1), s.undo());
}

test "UndoStack: capacity drops the oldest" {
    var s = UndoStack(u32, 3){};
    s.push(1);
    s.push(2);
    s.push(3);
    s.push(4);
    try testing.expectEqual(@as(?u32, 4), s.undo());
    try testing.expectEqual(@as(?u32, 3), s.undo());
    try testing.expectEqual(@as(?u32, 2), s.undo());
    try testing.expectEqual(@as(?u32, null), s.undo());
}
