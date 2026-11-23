//! Undo/Redo System
//!
//! Command pattern implementation for reversible actions.
//! Tracks all user actions and allows undo/redo navigation.

const std = @import("std");

const log = std.log.scoped(.undo);

/// Maximum undo history size
const MAX_HISTORY: usize = 100;

/// Action types that can be undone
pub const ActionType = enum(u8) {
    // Mixer actions
    set_track_volume,
    set_track_pan,
    set_track_mute,
    set_track_solo,
    set_master_volume,

    // Clip actions
    add_clip,
    remove_clip,
    move_clip,
    resize_clip,

    // Effect actions
    add_effect,
    remove_effect,
    set_effect_param,
    reorder_effects,

    // Project actions
    set_bpm,
    set_time_signature,
    set_project_name,
};

/// Stored action data for undo/redo
pub const Action = struct {
    action_type: ActionType,
    track: i8 = -1, // -1 for master/project level
    clip_id: u64 = 0, // For clip actions
    effect_slot: i8 = -1, // For effect actions
    param_index: i8 = -1, // For parameter actions

    // Value storage (before/after)
    old_float: f32 = 0,
    new_float: f32 = 0,
    old_int: i32 = 0,
    new_int: i32 = 0,
    old_double: f64 = 0,
    new_double: f64 = 0,

    // Description for UI
    description: [64]u8 = std.mem.zeroes([64]u8),

    pub fn setDescription(self: *Action, desc: []const u8) void {
        const len = @min(desc.len, self.description.len - 1);
        @memcpy(self.description[0..len], desc[0..len]);
        self.description[len] = 0;
    }

    pub fn getDescription(self: *const Action) []const u8 {
        const len = std.mem.indexOfScalar(u8, &self.description, 0) orelse self.description.len;
        return self.description[0..len];
    }
};

/// Undo/Redo manager
pub const UndoManager = struct {
    allocator: std.mem.Allocator,
    history: std.ArrayList(Action),
    current_index: usize, // Points to the next action to undo (0 = nothing to undo)

    // Callbacks for applying actions
    apply_fn: ?*const fn (*Action, bool) void, // action, is_undo

    pub fn init(allocator: std.mem.Allocator) UndoManager {
        return UndoManager{
            .allocator = allocator,
            .history = .empty,
            .current_index = 0,
            .apply_fn = null,
        };
    }

    pub fn deinit(self: *UndoManager) void {
        self.history.deinit(self.allocator);
    }

    /// Record a new action (clears redo history)
    pub fn record(self: *UndoManager, action: Action) !void {
        // Clear any redo history
        if (self.current_index < self.history.items.len) {
            self.history.shrinkRetainingCapacity(self.current_index);
        }

        // Trim history if too large
        if (self.history.items.len >= MAX_HISTORY) {
            // Remove oldest action
            _ = self.history.orderedRemove(0);
            if (self.current_index > 0) {
                self.current_index -= 1;
            }
        }

        try self.history.append(self.allocator, action);
        self.current_index = self.history.items.len;

        log.debug("Recorded: {s} (history: {})", .{ action.getDescription(), self.history.items.len });
    }

    /// Undo the last action
    pub fn undo(self: *UndoManager) bool {
        if (self.current_index == 0) {
            log.debug("Nothing to undo", .{});
            return false;
        }

        self.current_index -= 1;
        const action = &self.history.items[self.current_index];

        if (self.apply_fn) |apply| {
            apply(action, true);
        }

        log.info("Undo: {s}", .{action.getDescription()});
        return true;
    }

    /// Redo the next action
    pub fn redo(self: *UndoManager) bool {
        if (self.current_index >= self.history.items.len) {
            log.debug("Nothing to redo", .{});
            return false;
        }

        const action = &self.history.items[self.current_index];
        self.current_index += 1;

        if (self.apply_fn) |apply| {
            apply(action, false);
        }

        log.info("Redo: {s}", .{action.getDescription()});
        return true;
    }

    /// Check if undo is available
    pub fn canUndo(self: *const UndoManager) bool {
        return self.current_index > 0;
    }

    /// Check if redo is available
    pub fn canRedo(self: *const UndoManager) bool {
        return self.current_index < self.history.items.len;
    }

    /// Get next undo action description (or null)
    pub fn getUndoDescription(self: *const UndoManager) ?[]const u8 {
        if (self.current_index == 0) return null;
        return self.history.items[self.current_index - 1].getDescription();
    }

    /// Get next redo action description (or null)
    pub fn getRedoDescription(self: *const UndoManager) ?[]const u8 {
        if (self.current_index >= self.history.items.len) return null;
        return self.history.items[self.current_index].getDescription();
    }

    /// Clear all history
    pub fn clear(self: *UndoManager) void {
        self.history.clearRetainingCapacity();
        self.current_index = 0;
    }
};

// =============================================================================
// C API
// =============================================================================

/// C callback type for applying undo/redo actions
/// Parameters: action_type, track, is_undo, old_int, new_int, old_float, new_float, clip_id
pub const ApplyCallbackFn = *const fn (c_int, c_int, c_int, c_int, c_int, f32, f32, u64) callconv(.c) void;

var g_undo_manager: ?*UndoManager = null;
var g_allocator: ?std.mem.Allocator = null;
var g_apply_callback: ?ApplyCallbackFn = null;

/// Initialize undo system
export fn undo_init() callconv(.c) c_int {
    if (g_undo_manager != null) return 0;

    // Use page allocator for long-lived global state
    // (Don't use a local GPA that goes out of scope!)
    g_allocator = std.heap.page_allocator;

    const mgr = g_allocator.?.create(UndoManager) catch return -1;
    mgr.* = UndoManager.init(g_allocator.?);
    g_undo_manager = mgr;

    log.info("Undo system initialized", .{});
    return 0;
}

/// Set apply callback for undo/redo actions
export fn undo_set_apply_callback(callback: ?ApplyCallbackFn) callconv(.c) void {
    g_apply_callback = callback;
}

/// Perform undo
export fn undo_undo() callconv(.c) c_int {
    const mgr = g_undo_manager orelse return 0;

    if (mgr.current_index == 0) {
        return 0;
    }

    mgr.current_index -= 1;
    const action = &mgr.history.items[mgr.current_index];

    // Call the apply callback if set
    if (g_apply_callback) |callback| {
        callback(
            @backingInt(action.action_type),
            action.track,
            1, // is_undo = true
            action.old_int,
            action.new_int,
            action.old_float,
            action.new_float,
            action.clip_id,
        );
    }

    log.info("Undo: {s}", .{action.getDescription()});
    return 1;
}

/// Perform redo
export fn undo_redo() callconv(.c) c_int {
    const mgr = g_undo_manager orelse return 0;

    if (mgr.current_index >= mgr.history.items.len) {
        return 0;
    }

    const action = &mgr.history.items[mgr.current_index];
    mgr.current_index += 1;

    // Call the apply callback if set
    if (g_apply_callback) |callback| {
        callback(
            @backingInt(action.action_type),
            action.track,
            0, // is_undo = false
            action.old_int,
            action.new_int,
            action.old_float,
            action.new_float,
            action.clip_id,
        );
    }

    log.info("Redo: {s}", .{action.getDescription()});
    return 1;
}

/// Check if can undo
export fn undo_can_undo() callconv(.c) c_int {
    const mgr = g_undo_manager orelse return 0;
    return if (mgr.canUndo()) 1 else 0;
}

/// Check if can redo
export fn undo_can_redo() callconv(.c) c_int {
    const mgr = g_undo_manager orelse return 0;
    return if (mgr.canRedo()) 1 else 0;
}

/// Record a float parameter change
export fn undo_record_float(
    action_type: c_int,
    track: c_int,
    old_value: f32,
    new_value: f32,
    desc_ptr: [*:0]const u8,
) callconv(.c) c_int {
    const mgr = g_undo_manager orelse return -1;

    var action = Action{
        .action_type = @fromBackingInt(@intCast(@as(u8, @intCast(action_type)))),
        .track = @intCast(track),
        .old_float = old_value,
        .new_float = new_value,
    };
    action.setDescription(std.mem.span(desc_ptr));

    mgr.record(action) catch return -1;
    return 0;
}

/// Record an integer parameter change
export fn undo_record_int(
    action_type: c_int,
    track: c_int,
    old_value: c_int,
    new_value: c_int,
    desc_ptr: [*:0]const u8,
) callconv(.c) c_int {
    const mgr = g_undo_manager orelse return -1;

    var action = Action{
        .action_type = @fromBackingInt(@intCast(@as(u8, @intCast(action_type)))),
        .track = @intCast(track),
        .old_int = old_value,
        .new_int = new_value,
    };
    action.setDescription(std.mem.span(desc_ptr));

    mgr.record(action) catch return -1;
    return 0;
}

/// Clear undo history
export fn undo_clear() callconv(.c) void {
    if (g_undo_manager) |mgr| {
        mgr.clear();
    }
}

/// Record a clip action (add/remove) with clip_id stored in old_double
export fn undo_record_clip(
    action_type: c_int,
    track: c_int,
    clip_id: u64,
    desc_ptr: [*:0]const u8,
) callconv(.c) c_int {
    const mgr = g_undo_manager orelse return -1;

    var action = Action{
        .action_type = @fromBackingInt(@intCast(@as(u8, @intCast(action_type)))),
        .track = @intCast(track),
        .clip_id = clip_id,
    };
    action.setDescription(std.mem.span(desc_ptr));

    mgr.record(action) catch return -1;
    return 0;
}

/// Get undo description (returns null-terminated string or null)
export fn undo_get_undo_desc() callconv(.c) ?[*:0]const u8 {
    const mgr = g_undo_manager orelse return null;
    const desc = mgr.getUndoDescription() orelse return null;
    return @ptrCast(desc.ptr);
}

/// Get redo description (returns null-terminated string or null)
export fn undo_get_redo_desc() callconv(.c) ?[*:0]const u8 {
    const mgr = g_undo_manager orelse return null;
    const desc = mgr.getRedoDescription() orelse return null;
    return @ptrCast(desc.ptr);
}

// =============================================================================
// Tests
// =============================================================================

test "undo manager basic operations" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var mgr = UndoManager.init(allocator);
    defer mgr.deinit();

    // Initially nothing to undo/redo
    try testing.expect(!mgr.canUndo());
    try testing.expect(!mgr.canRedo());
    try testing.expect(mgr.getUndoDescription() == null);
    try testing.expect(mgr.getRedoDescription() == null);

    // Record an action
    var action1 = Action{
        .action_type = .set_track_volume,
        .track = 0,
        .old_float = 0.5,
        .new_float = 0.8,
    };
    action1.setDescription("Set Track 1 Volume");
    try mgr.record(action1);

    // Now we can undo but not redo
    try testing.expect(mgr.canUndo());
    try testing.expect(!mgr.canRedo());
    try testing.expectEqualStrings("Set Track 1 Volume", mgr.getUndoDescription().?);
}

test "undo/redo navigation" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var mgr = UndoManager.init(allocator);
    defer mgr.deinit();

    // Record three actions
    var action1 = Action{ .action_type = .set_track_volume, .old_float = 0.5, .new_float = 0.8 };
    action1.setDescription("Action 1");
    try mgr.record(action1);

    var action2 = Action{ .action_type = .set_track_pan, .old_float = 0.0, .new_float = -0.5 };
    action2.setDescription("Action 2");
    try mgr.record(action2);

    var action3 = Action{ .action_type = .set_track_mute, .old_int = 0, .new_int = 1 };
    action3.setDescription("Action 3");
    try mgr.record(action3);

    // Should have 3 in history
    try testing.expectEqual(@as(usize, 3), mgr.history.items.len);
    try testing.expectEqual(@as(usize, 3), mgr.current_index);

    // Undo once
    try testing.expect(mgr.undo());
    try testing.expectEqual(@as(usize, 2), mgr.current_index);
    try testing.expect(mgr.canUndo());
    try testing.expect(mgr.canRedo());
    try testing.expectEqualStrings("Action 2", mgr.getUndoDescription().?);
    try testing.expectEqualStrings("Action 3", mgr.getRedoDescription().?);

    // Undo again
    try testing.expect(mgr.undo());
    try testing.expectEqual(@as(usize, 1), mgr.current_index);

    // Undo once more
    try testing.expect(mgr.undo());
    try testing.expectEqual(@as(usize, 0), mgr.current_index);
    try testing.expect(!mgr.canUndo());
    try testing.expect(mgr.canRedo());

    // Can't undo when at beginning
    try testing.expect(!mgr.undo());

    // Redo back
    try testing.expect(mgr.redo());
    try testing.expectEqual(@as(usize, 1), mgr.current_index);
    try testing.expect(mgr.redo());
    try testing.expectEqual(@as(usize, 2), mgr.current_index);
    try testing.expect(mgr.redo());
    try testing.expectEqual(@as(usize, 3), mgr.current_index);

    // Can't redo when at end
    try testing.expect(!mgr.redo());
}

test "undo clears redo history on new action" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var mgr = UndoManager.init(allocator);
    defer mgr.deinit();

    // Record two actions
    var action1 = Action{ .action_type = .set_track_volume };
    action1.setDescription("Action 1");
    try mgr.record(action1);

    var action2 = Action{ .action_type = .set_track_pan };
    action2.setDescription("Action 2");
    try mgr.record(action2);

    // Undo once
    try testing.expect(mgr.undo());
    try testing.expectEqual(@as(usize, 1), mgr.current_index);
    try testing.expectEqual(@as(usize, 2), mgr.history.items.len);

    // Record new action - should clear redo history
    var action3 = Action{ .action_type = .set_track_mute };
    action3.setDescription("Action 3");
    try mgr.record(action3);

    try testing.expectEqual(@as(usize, 2), mgr.history.items.len);
    try testing.expectEqual(@as(usize, 2), mgr.current_index);
    try testing.expect(!mgr.canRedo());
    try testing.expectEqualStrings("Action 3", mgr.getUndoDescription().?);
}

test "undo history limit" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var mgr = UndoManager.init(allocator);
    defer mgr.deinit();

    // Record more than MAX_HISTORY actions
    for (0..MAX_HISTORY + 10) |i| {
        var action = Action{ .action_type = .set_track_volume, .old_float = @floatFromInt(i) };
        action.setDescription("Action");
        try mgr.record(action);
    }

    // Should be capped at MAX_HISTORY
    try testing.expectEqual(MAX_HISTORY, mgr.history.items.len);
}

test "undo clear" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var mgr = UndoManager.init(allocator);
    defer mgr.deinit();

    // Record actions
    for (0..5) |_| {
        const action = Action{ .action_type = .set_track_volume };
        try mgr.record(action);
    }

    try testing.expectEqual(@as(usize, 5), mgr.history.items.len);

    // Clear
    mgr.clear();

    try testing.expectEqual(@as(usize, 0), mgr.history.items.len);
    try testing.expectEqual(@as(usize, 0), mgr.current_index);
    try testing.expect(!mgr.canUndo());
    try testing.expect(!mgr.canRedo());
}

test "action description handling" {
    const testing = std.testing;

    var action = Action{ .action_type = .set_track_volume };

    // Set short description
    action.setDescription("Short");
    try testing.expectEqualStrings("Short", action.getDescription());

    // Set longer description
    action.setDescription("This is a longer description for the action");
    try testing.expectEqualStrings("This is a longer description for the action", action.getDescription());

    // Set very long description (should be truncated)
    const long_desc = &@as([100]u8, @splat('A'));
    action.setDescription(long_desc);
    try testing.expectEqual(@as(usize, 63), action.getDescription().len);
}

// =============================================================================
// C API Tests
// =============================================================================

/// Helper to setup C API for testing with test allocator
fn setupCApi(allocator: std.mem.Allocator) !void {
    g_allocator = allocator;
    const mgr = try allocator.create(UndoManager);
    mgr.* = UndoManager.init(allocator);
    g_undo_manager = mgr;
}

/// Helper to teardown C API after testing
fn teardownCApi() void {
    if (g_undo_manager) |mgr| {
        mgr.deinit();
        if (g_allocator) |alloc| {
            alloc.destroy(mgr);
        }
    }
    g_undo_manager = null;
    g_allocator = null;
    g_apply_callback = null;
}

test "C API: undo_init() initializes global state" {
    const testing = std.testing;

    // Save current state to restore later
    const saved_mgr = g_undo_manager;
    const saved_alloc = g_allocator;
    const saved_cb = g_apply_callback;

    defer {
        // Restore original state
        g_undo_manager = saved_mgr;
        g_allocator = saved_alloc;
        g_apply_callback = saved_cb;
    }

    // Clean up any existing state
    g_undo_manager = null;
    g_allocator = null;
    g_apply_callback = null;

    // Initialize - note this creates its own GPA which we can't easily free
    const result = undo_init();
    try testing.expectEqual(@as(c_int, 0), result);
    try testing.expect(g_undo_manager != null);
    try testing.expect(g_allocator != null);

    // Second init should return 0 (already initialized)
    const result2 = undo_init();
    try testing.expectEqual(@as(c_int, 0), result2);

    // Clear the manager but don't free (GPA cleanup is complex)
    if (g_undo_manager) |mgr| {
        mgr.clear();
    }
}

test "C API: undo_record_float() records float parameter changes" {
    const testing = std.testing;

    // Setup
    try setupCApi(testing.allocator);
    defer teardownCApi();

    const action_type = @backingInt(ActionType.set_track_volume);
    const track = 0;
    const old_value: f32 = 0.5;
    const new_value: f32 = 0.8;
    const description = "Set Track Volume";

    // Record action
    const result = undo_record_float(
        action_type,
        track,
        old_value,
        new_value,
        description.ptr,
    );

    try testing.expectEqual(@as(c_int, 0), result);

    // Verify action was recorded
    const mgr = g_undo_manager.?;
    try testing.expectEqual(@as(usize, 1), mgr.history.items.len);
    try testing.expectEqual(@as(usize, 1), mgr.current_index);

    const recorded_action = &mgr.history.items[0];
    try testing.expectEqual(ActionType.set_track_volume, recorded_action.action_type);
    try testing.expectEqual(@as(i8, 0), recorded_action.track);
    try testing.expectEqual(old_value, recorded_action.old_float);
    try testing.expectEqual(new_value, recorded_action.new_float);
    try testing.expectEqualStrings("Set Track Volume", recorded_action.getDescription());
}

test "C API: undo_record_int() records integer parameter changes" {
    const testing = std.testing;

    // Setup
    try setupCApi(testing.allocator);
    defer teardownCApi();

    const action_type = @backingInt(ActionType.set_track_mute);
    const track = 1;
    const old_value: c_int = 0;
    const new_value: c_int = 1;
    const description = "Mute Track 2";

    // Record action
    const result = undo_record_int(
        action_type,
        track,
        old_value,
        new_value,
        description.ptr,
    );

    try testing.expectEqual(@as(c_int, 0), result);

    // Verify action was recorded
    const mgr = g_undo_manager.?;
    try testing.expectEqual(@as(usize, 1), mgr.history.items.len);
    try testing.expectEqual(@as(usize, 1), mgr.current_index);

    const recorded_action = &mgr.history.items[0];
    try testing.expectEqual(ActionType.set_track_mute, recorded_action.action_type);
    try testing.expectEqual(@as(i8, 1), recorded_action.track);
    try testing.expectEqual(@as(i32, 0), recorded_action.old_int);
    try testing.expectEqual(@as(i32, 1), recorded_action.new_int);
    try testing.expectEqualStrings("Mute Track 2", recorded_action.getDescription());
}

test "C API: undo_undo() and undo_redo() perform operations" {
    const testing = std.testing;

    // Setup
    try setupCApi(testing.allocator);
    defer teardownCApi();

    // Record some actions
    const action_type = @backingInt(ActionType.set_track_volume);
    _ = undo_record_float(action_type, 0, 0.5, 0.8, "Action 1");
    _ = undo_record_float(action_type, 1, 0.6, 0.7, "Action 2");
    _ = undo_record_float(action_type, 2, 0.3, 0.9, "Action 3");

    const mgr = g_undo_manager.?;
    try testing.expectEqual(@as(usize, 3), mgr.history.items.len);
    try testing.expectEqual(@as(usize, 3), mgr.current_index);

    // Test undo
    var result = undo_undo();
    try testing.expectEqual(@as(c_int, 1), result);
    try testing.expectEqual(@as(usize, 2), mgr.current_index);

    result = undo_undo();
    try testing.expectEqual(@as(c_int, 1), result);
    try testing.expectEqual(@as(usize, 1), mgr.current_index);

    result = undo_undo();
    try testing.expectEqual(@as(c_int, 1), result);
    try testing.expectEqual(@as(usize, 0), mgr.current_index);

    // Can't undo anymore
    result = undo_undo();
    try testing.expectEqual(@as(c_int, 0), result);
    try testing.expectEqual(@as(usize, 0), mgr.current_index);

    // Test redo
    result = undo_redo();
    try testing.expectEqual(@as(c_int, 1), result);
    try testing.expectEqual(@as(usize, 1), mgr.current_index);

    result = undo_redo();
    try testing.expectEqual(@as(c_int, 1), result);
    try testing.expectEqual(@as(usize, 2), mgr.current_index);

    result = undo_redo();
    try testing.expectEqual(@as(c_int, 1), result);
    try testing.expectEqual(@as(usize, 3), mgr.current_index);

    // Can't redo anymore
    result = undo_redo();
    try testing.expectEqual(@as(c_int, 0), result);
    try testing.expectEqual(@as(usize, 3), mgr.current_index);
}

test "C API: undo_can_undo() and undo_can_redo() check availability" {
    const testing = std.testing;

    // Setup
    try setupCApi(testing.allocator);
    defer teardownCApi();

    // Initially nothing to undo/redo
    try testing.expectEqual(@as(c_int, 0), undo_can_undo());
    try testing.expectEqual(@as(c_int, 0), undo_can_redo());

    // Record an action
    const action_type = @backingInt(ActionType.set_track_volume);
    _ = undo_record_float(action_type, 0, 0.5, 0.8, "Test Action");

    // Can undo, can't redo
    try testing.expectEqual(@as(c_int, 1), undo_can_undo());
    try testing.expectEqual(@as(c_int, 0), undo_can_redo());

    // Undo once
    _ = undo_undo();

    // Can't undo, can redo
    try testing.expectEqual(@as(c_int, 0), undo_can_undo());
    try testing.expectEqual(@as(c_int, 1), undo_can_redo());

    // Redo
    _ = undo_redo();

    // Can undo, can't redo
    try testing.expectEqual(@as(c_int, 1), undo_can_undo());
    try testing.expectEqual(@as(c_int, 0), undo_can_redo());
}

test "C API: undo_get_undo_desc() and undo_get_redo_desc() retrieve descriptions" {
    const testing = std.testing;

    // Setup
    try setupCApi(testing.allocator);
    defer teardownCApi();

    // Initially no descriptions
    try testing.expect(undo_get_undo_desc() == null);
    try testing.expect(undo_get_redo_desc() == null);

    // Record three actions with distinct descriptions
    const action_type = @backingInt(ActionType.set_track_volume);
    _ = undo_record_float(action_type, 0, 0.5, 0.8, "First Action");
    _ = undo_record_float(action_type, 1, 0.6, 0.7, "Second Action");
    _ = undo_record_float(action_type, 2, 0.3, 0.9, "Third Action");

    // At end of history - can get undo description but not redo
    const undo_desc1 = undo_get_undo_desc();
    try testing.expect(undo_desc1 != null);
    try testing.expectEqualStrings("Third Action", std.mem.span(undo_desc1.?));
    try testing.expect(undo_get_redo_desc() == null);

    // Undo once
    _ = undo_undo();

    // Can get both descriptions
    const undo_desc2 = undo_get_undo_desc();
    const redo_desc1 = undo_get_redo_desc();
    try testing.expect(undo_desc2 != null);
    try testing.expect(redo_desc1 != null);
    try testing.expectEqualStrings("Second Action", std.mem.span(undo_desc2.?));
    try testing.expectEqualStrings("Third Action", std.mem.span(redo_desc1.?));

    // Undo again
    _ = undo_undo();

    const undo_desc3 = undo_get_undo_desc();
    const redo_desc2 = undo_get_redo_desc();
    try testing.expect(undo_desc3 != null);
    try testing.expect(redo_desc2 != null);
    try testing.expectEqualStrings("First Action", std.mem.span(undo_desc3.?));
    try testing.expectEqualStrings("Second Action", std.mem.span(redo_desc2.?));

    // Undo to beginning
    _ = undo_undo();

    // No undo description, but can get redo
    try testing.expect(undo_get_undo_desc() == null);
    const redo_desc3 = undo_get_redo_desc();
    try testing.expect(redo_desc3 != null);
    try testing.expectEqualStrings("First Action", std.mem.span(redo_desc3.?));
}

test "C API: undo_clear() clears history" {
    const testing = std.testing;

    // Setup
    try setupCApi(testing.allocator);
    defer teardownCApi();

    // Record actions
    const action_type = @backingInt(ActionType.set_track_volume);
    _ = undo_record_float(action_type, 0, 0.5, 0.8, "Action 1");
    _ = undo_record_float(action_type, 1, 0.6, 0.7, "Action 2");
    _ = undo_record_float(action_type, 2, 0.3, 0.9, "Action 3");

    const mgr = g_undo_manager.?;
    try testing.expectEqual(@as(usize, 3), mgr.history.items.len);

    // Clear history
    undo_clear();

    // Verify cleared
    try testing.expectEqual(@as(usize, 0), mgr.history.items.len);
    try testing.expectEqual(@as(usize, 0), mgr.current_index);
    try testing.expectEqual(@as(c_int, 0), undo_can_undo());
    try testing.expectEqual(@as(c_int, 0), undo_can_redo());
    try testing.expect(undo_get_undo_desc() == null);
    try testing.expect(undo_get_redo_desc() == null);
}

test "C API: apply callback is invoked correctly" {
    const testing = std.testing;

    // Callback tracking structure
    const CallbackData = struct {
        var call_count: usize = 0;
        var last_action_type: c_int = -1;
        var last_track: c_int = -1;
        var last_is_undo: c_int = -1;
        var last_old_int: c_int = 0;
        var last_new_int: c_int = 0;
        var last_old_float: f32 = 0;
        var last_new_float: f32 = 0;

        fn callback(
            action_type: c_int,
            track: c_int,
            is_undo: c_int,
            old_int: c_int,
            new_int: c_int,
            old_float: f32,
            new_float: f32,
            clip_id: u64,
        ) callconv(.c) void {
            _ = clip_id;
            call_count += 1;
            last_action_type = action_type;
            last_track = track;
            last_is_undo = is_undo;
            last_old_int = old_int;
            last_new_int = new_int;
            last_old_float = old_float;
            last_new_float = new_float;
        }

        fn reset() void {
            call_count = 0;
            last_action_type = -1;
            last_track = -1;
            last_is_undo = -1;
            last_old_int = 0;
            last_new_int = 0;
            last_old_float = 0;
            last_new_float = 0;
        }
    };

    // Setup
    try setupCApi(testing.allocator);
    defer teardownCApi();

    // Set callback
    undo_set_apply_callback(CallbackData.callback);
    CallbackData.reset();

    // Record float action
    const action_type = @backingInt(ActionType.set_track_volume);
    _ = undo_record_float(action_type, 0, 0.5, 0.8, "Volume Change");

    // Recording doesn't trigger callback
    try testing.expectEqual(@as(usize, 0), CallbackData.call_count);

    // Undo triggers callback
    _ = undo_undo();
    try testing.expectEqual(@as(usize, 1), CallbackData.call_count);
    try testing.expectEqual(action_type, CallbackData.last_action_type);
    try testing.expectEqual(@as(c_int, 0), CallbackData.last_track);
    try testing.expectEqual(@as(c_int, 1), CallbackData.last_is_undo); // is_undo = true
    try testing.expectEqual(@as(f32, 0.5), CallbackData.last_old_float);
    try testing.expectEqual(@as(f32, 0.8), CallbackData.last_new_float);

    CallbackData.reset();

    // Redo triggers callback with is_undo = false
    _ = undo_redo();
    try testing.expectEqual(@as(usize, 1), CallbackData.call_count);
    try testing.expectEqual(@as(c_int, 0), CallbackData.last_is_undo); // is_undo = false
    try testing.expectEqual(@as(f32, 0.5), CallbackData.last_old_float);
    try testing.expectEqual(@as(f32, 0.8), CallbackData.last_new_float);

    CallbackData.reset();

    // Test with integer action
    const mute_action = @backingInt(ActionType.set_track_mute);
    _ = undo_record_int(mute_action, 2, 0, 1, "Mute Track");
    _ = undo_undo();

    try testing.expectEqual(@as(usize, 1), CallbackData.call_count);
    try testing.expectEqual(mute_action, CallbackData.last_action_type);
    try testing.expectEqual(@as(c_int, 2), CallbackData.last_track);
    try testing.expectEqual(@as(c_int, 1), CallbackData.last_is_undo);
    try testing.expectEqual(@as(c_int, 0), CallbackData.last_old_int);
    try testing.expectEqual(@as(c_int, 1), CallbackData.last_new_int);
}

test "C API: operations without initialization" {
    const testing = std.testing;

    // Save current state
    const saved_mgr = g_undo_manager;
    const saved_alloc = g_allocator;

    // Clear global state
    g_undo_manager = null;
    g_allocator = null;

    defer {
        // Restore state
        g_undo_manager = saved_mgr;
        g_allocator = saved_alloc;
    }

    // Operations should fail gracefully without initialization
    try testing.expectEqual(@as(c_int, 0), undo_can_undo());
    try testing.expectEqual(@as(c_int, 0), undo_can_redo());
    try testing.expect(undo_get_undo_desc() == null);
    try testing.expect(undo_get_redo_desc() == null);
    try testing.expectEqual(@as(c_int, 0), undo_undo());
    try testing.expectEqual(@as(c_int, 0), undo_redo());

    const action_type = @backingInt(ActionType.set_track_volume);
    try testing.expectEqual(@as(c_int, -1), undo_record_float(action_type, 0, 0.5, 0.8, "Test"));
    try testing.expectEqual(@as(c_int, -1), undo_record_int(action_type, 0, 0, 1, "Test"));
}
