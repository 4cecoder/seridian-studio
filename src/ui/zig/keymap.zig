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
    file_export_wav,
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
    .{ .key = 'E', .cmd = true, .shift = true, .action = .file_export_wav },
    .{ .key = 'P', .cmd = true, .shift = true, .action = .popout_piano_roll },
    .{ .key = 'M', .cmd = true, .shift = true, .action = .popout_mixer },
    // Plain keys kept from the original timeline shortcuts. Plain letters stay free for the computer-keyboard piano.
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

// ---- help text rendered from the table ----

/// Which modifier name the help shows for the `cmd` flag.
pub const Platform = enum { linux_windows, macos };

/// Platform of this build.
pub const native_platform: Platform = if (@import("builtin").os.tag == .macos) .macos else .linux_windows;

/// Buffer size that holds the full help text with room to spare.
pub const help_capacity = 2048;
/// Buffer size for the one-line status-bar hint.
pub const hint_capacity = 256;

pub const RenderError = error{NoSpaceLeft};

/// "Cmd" on macOS, "Ctrl" elsewhere.
pub fn cmdName(platform: Platform) []const u8 {
    return switch (platform) {
        .linux_windows => "Ctrl",
        .macos => "Cmd",
    };
}

const Group = enum { transport, edit, file, view };

const group_titles = [_][]const u8{ "TRANSPORT", "EDIT", "FILE", "VIEW" };

fn groupOf(action: Action) ?Group {
    return switch (action) {
        .none => null,
        .play_stop, .stop_and_rewind => .transport,
        .undo, .redo, .select_all, .copy, .cut, .paste, .duplicate, .delete, .split_at_playhead => .edit,
        .file_new, .file_open, .file_save, .file_save_as, .file_export_wav => .file,
        .view_arrangement, .view_piano_roll, .zoom_in, .zoom_out, .popout_piano_roll, .popout_mixer => .view,
    };
}

/// Short human label of an action, as shown in the help.
pub fn actionLabel(action: Action) []const u8 {
    return switch (action) {
        .none => "",
        .play_stop => "Play / pause",
        .stop_and_rewind => "Stop",
        .undo => "Undo",
        .redo => "Redo",
        .select_all => "Select all",
        .copy => "Copy",
        .cut => "Cut",
        .paste => "Paste",
        .duplicate => "Duplicate",
        .delete => "Delete",
        .split_at_playhead => "Split at playhead",
        .file_new => "New project",
        .file_open => "Open project",
        .file_save => "Save",
        .file_save_as => "Save As",
        .file_export_wav => "Export WAV",
        .view_arrangement => "Arrangement tab",
        .view_piano_roll => "Piano Roll tab",
        .zoom_in => "Zoom in",
        .zoom_out => "Zoom out",
        .popout_piano_roll => "Pop out Piano Roll",
        .popout_mixer => "Pop out Mixer",
    };
}

const Writer = struct {
    buf: []u8,
    len: usize = 0,

    fn put(self: *Writer, text: []const u8) RenderError!void {
        if (self.len + text.len > self.buf.len) return error.NoSpaceLeft;
        @memcpy(self.buf[self.len..][0..text.len], text);
        self.len += text.len;
    }
};

fn keyName(out: *Writer, key: i32) RenderError!void {
    switch (key) {
        key_space => try out.put("Space"),
        key_enter => try out.put("Enter"),
        key_backspace => try out.put("Backspace"),
        key_delete => try out.put("Delete"),
        else => {
            if (key < 33 or key > 126) return error.NoSpaceLeft;
            const ch: [1]u8 = .{@intCast(key)};
            try out.put(&ch);
        },
    }
}

fn writeBinding(out: *Writer, b: Binding, platform: Platform) RenderError!void {
    if (b.cmd) {
        try out.put(cmdName(platform));
        try out.put("+");
    }
    if (b.shift) try out.put("Shift+");
    try keyName(out, b.key);
}

/// The key text of one binding ("Ctrl+Shift+S", "Space") in `out`.
pub fn bindingName(out: []u8, b: Binding, platform: Platform) RenderError![]const u8 {
    var w = Writer{ .buf = out };
    try writeBinding(&w, b, platform);
    return out[0..w.len];
}

/// Renders every binding of `bindings`, grouped Transport, Edit, File, View, one "<keys>  <label>" line each.
/// Returns the text in `buf`, or error.NoSpaceLeft when it does not fit.
pub fn renderHelp(buf: []u8, platform: Platform) RenderError![]const u8 {
    var w = Writer{ .buf = buf };
    for (group_titles, 0..) |title, gi| {
        if (gi != 0) try w.put("\n");
        try w.put(title);
        try w.put("\n");
        for (bindings) |b| {
            const g = groupOf(b.action) orelse continue;
            if (@backingInt(g) != gi) continue;
            try writeBinding(&w, b, platform);
            try w.put("  ");
            try w.put(actionLabel(b.action));
            try w.put("\n");
        }
    }
    return buf[0..w.len];
}

/// The first binding of `action`, or null when unbound.
pub fn firstBinding(action: Action) ?Binding {
    for (bindings) |b| {
        if (b.action == action) return b;
    }
    return null;
}

const hint_entries = [_]struct { action: Action, label: []const u8 }{
    .{ .action = .play_stop, .label = "play" },
    .{ .action = .stop_and_rewind, .label = "stop" },
    .{ .action = .split_at_playhead, .label = "split" },
    .{ .action = .zoom_in, .label = "zoom in" },
    .{ .action = .file_save, .label = "save" },
    .{ .action = .file_save_as, .label = "save as" },
    .{ .action = .file_export_wav, .label = "export WAV" },
};

/// One-line hint for the status bar, built from the table's first binding of each listed action.
pub fn renderHint(buf: []u8, platform: Platform) RenderError![]const u8 {
    var w = Writer{ .buf = buf };
    for (hint_entries, 0..) |entry, i| {
        const b = firstBinding(entry.action) orelse continue;
        if (i != 0) try w.put(" \u{b7} ");
        try writeBinding(&w, b, platform);
        try w.put(" ");
        try w.put(entry.label);
    }
    return buf[0..w.len];
}

/// C ABI for the window (app/externs.zig). Returns the Action tag as an int; the
/// SERIDIAN_ACTION_* constants in app/externs.zig list the tags in the same order (tested there).
pub export fn seridian_keymap_lookup(key: i32, modifiers: u32) callconv(.c) c_int {
    return @intCast(@backingInt(lookup(key, modifiers)));
}

/// C ABI: the help text for this platform, NUL-terminated, into `out` (`capacity` bytes). Returns the text
/// length, or -1 when it does not fit (`out` then holds an empty string).
pub export fn seridian_keymap_help(out: [*]u8, capacity: usize) callconv(.c) c_int {
    return exportText(out, capacity, renderHelp(out[0..capacity], native_platform));
}

/// C ABI: the one-line status-bar hint; same contract as seridian_keymap_help.
pub export fn seridian_keymap_hint(out: [*]u8, capacity: usize) callconv(.c) c_int {
    return exportText(out, capacity, renderHint(out[0..capacity], native_platform));
}

fn exportText(out: [*]u8, capacity: usize, rendered: RenderError![]const u8) c_int {
    const text = rendered catch {
        if (capacity > 0) out[0] = 0;
        return -1;
    };
    if (text.len >= capacity) {
        if (capacity > 0) out[0] = 0;
        return -1;
    }
    out[text.len] = 0;
    return @intCast(text.len);
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

test "help: every binding appears in the rendered help" {
    var buf: [help_capacity]u8 = undefined;
    for ([_]Platform{ .linux_windows, .macos }) |platform| {
        const text = try renderHelp(&buf, platform);
        for (bindings) |b| {
            var name: [32]u8 = undefined;
            const keys = try bindingName(&name, b, platform);
            var line: [96]u8 = undefined;
            const expect = try std.fmt.bufPrint(&line, "{s}  {s}\n", .{ keys, actionLabel(b.action) });
            try testing.expect(std.mem.indexOf(u8, text, expect) != null);
        }
    }
}

test "help: grouped under Transport, Edit, File, View" {
    var buf: [help_capacity]u8 = undefined;
    const text = try renderHelp(&buf, .linux_windows);
    const t = std.mem.indexOf(u8, text, "TRANSPORT\n") orelse return error.MissingGroup;
    const e = std.mem.indexOf(u8, text, "EDIT\n") orelse return error.MissingGroup;
    const f = std.mem.indexOf(u8, text, "FILE\n") orelse return error.MissingGroup;
    const v = std.mem.indexOf(u8, text, "VIEW\n") orelse return error.MissingGroup;
    try testing.expect(t < e and e < f and f < v);
}

test "help: Linux render says Ctrl, never Cmd; macOS says Cmd" {
    var buf: [help_capacity]u8 = undefined;
    const linux = try renderHelp(&buf, .linux_windows);
    try testing.expect(std.mem.indexOf(u8, linux, "Cmd") == null);
    try testing.expect(std.mem.indexOf(u8, linux, "Ctrl+Shift+S  ") != null);
    var buf2: [help_capacity]u8 = undefined;
    const mac = try renderHelp(&buf2, .macos);
    try testing.expect(std.mem.indexOf(u8, mac, "Ctrl") == null);
    try testing.expect(std.mem.indexOf(u8, mac, "Cmd+Shift+S  ") != null);
}

test "help: a too-small buffer reports an error instead of overflowing" {
    var tiny: [16]u8 = undefined;
    try testing.expectError(error.NoSpaceLeft, renderHelp(&tiny, .linux_windows));
}

test "help: status hint names the table's keys and fits its buffer" {
    var buf: [hint_capacity]u8 = undefined;
    const hint = try renderHint(&buf, .linux_windows);
    try testing.expect(std.mem.indexOf(u8, hint, "Cmd") == null);
    try testing.expect(std.mem.indexOf(u8, hint, "Ctrl+Shift+E") != null);
    try testing.expect(std.mem.indexOf(u8, hint, "Space") != null);
}

test "lookup: export WAV is Ctrl+Shift+E in the table" {
    try testing.expectEqual(Action.file_export_wav, lookup('E', piano_math.modifier_ctrl | modifier_shift));
}

test "cmdName: Ctrl off macOS, Cmd on macOS" {
    try testing.expectEqualStrings("Ctrl", cmdName(.linux_windows));
    try testing.expectEqualStrings("Cmd", cmdName(.macos));
}

test "exportText: NUL-terminates and rejects a buffer with no room for the NUL" {
    var buf: [help_capacity]u8 = undefined;
    const n = seridian_keymap_help(&buf, buf.len);
    try testing.expect(n > 0);
    try testing.expectEqual(@as(u8, 0), buf[@intCast(n)]);
    var tiny: [8]u8 = undefined;
    try testing.expectEqual(@as(c_int, -1), seridian_keymap_help(&tiny, tiny.len));
    try testing.expectEqual(@as(u8, 0), tiny[0]);
}

test "U5: plain S is unbound so the computer-keyboard note S (D) reaches the piano" {
    try testing.expectEqual(Action.none, lookup('S', 0));
    try testing.expect(keyToPitch('S', 60) >= 0);
}

test "U5: Ctrl+E (Ableton's split) still splits" {
    try testing.expectEqual(Action.split_at_playhead, lookup('E', piano_math.modifier_ctrl));
    try testing.expectEqual(Action.split_at_playhead, lookup('E', piano_math.modifier_super));
}

test "U5: no plain binding shadows a computer-keyboard piano key or the octave keys" {
    for (bindings) |b| {
        if (b.cmd or b.shift) continue;
        try testing.expect(keyToPitch(b.key, 60) < 0);
        try testing.expect(b.key != 'Z' and b.key != 'X');
    }
}

test "help: split is listed once, as Ctrl+E" {
    var buf: [help_capacity]u8 = undefined;
    const text = try renderHelp(&buf, .linux_windows);
    try testing.expect(std.mem.indexOf(u8, text, "Ctrl+E  Split at playhead\n") != null);
    try testing.expect(std.mem.indexOf(u8, text, "\nS  Split") == null);
}
