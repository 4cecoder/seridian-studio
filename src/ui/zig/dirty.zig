//! Unsaved-changes tracking. Pure logic: no UI, no engine.

const std = @import("std");
const testing = std.testing;

/// Tracks whether the session has changes that were not saved. The window feeds it the session signature (the hash
/// of mixer, tempo, clips and MIDI notes that autosave already computes); any change in it marks the session dirty.
pub const Dirty = struct {
    dirty: bool = false,
    /// Bumped on every mark, so a caller can tell "changed again" from "still the same change".
    generation: u64 = 0,
    /// The signature last seen or saved.
    last_signature: u64 = 0,

    /// Records an edit.
    pub fn mark(self: *Dirty) void {
        self.dirty = true;
        self.generation +%= 1;
    }

    pub fn is_dirty(self: *const Dirty) bool {
        return self.dirty;
    }

    /// The session was saved (or opened, or cleared) with `signature`: nothing is unsaved.
    pub fn clear_on_save(self: *Dirty, signature: u64) void {
        self.dirty = false;
        self.last_signature = signature;
    }

    /// Adopts `signature` as the reference without touching the dirty flag (startup, after a recovery restore).
    pub fn rebase(self: *Dirty, signature: u64) void {
        self.last_signature = signature;
    }

    /// Feeds the current signature. A different one marks dirty. Returns true when it did.
    pub fn observe(self: *Dirty, signature: u64) bool {
        if (signature == self.last_signature) return false;
        self.last_signature = signature;
        self.mark();
        return true;
    }
};

/// The user's answer to "Save changes?".
pub const Answer = enum { yes, no, cancel };

/// What the pending operation (close, New, Open) does next.
pub const Step = enum { proceed, save, cancel };

/// True when the operation must ask "Save changes?" first.
pub fn needsPrompt(d: *const Dirty) bool {
    return d.is_dirty();
}

/// Save: save first. Don't save: carry on and discard. Cancel: stop.
pub fn decide(answer: Answer) Step {
    return switch (answer) {
        .yes => .save,
        .no => .proceed,
        .cancel => .cancel,
    };
}

/// After a Save, carry on only when nothing is left unsaved (a Save As prompt the user cancelled leaves it dirty).
pub fn afterSave(d: *const Dirty) Step {
    return if (d.is_dirty()) .cancel else .proceed;
}

test "Dirty: starts clean" {
    const d = Dirty{};
    try testing.expect(!d.is_dirty());
    try testing.expectEqual(@as(u64, 0), d.generation);
}

test "Dirty: mark makes it dirty and bumps the generation" {
    var d = Dirty{};
    d.mark();
    try testing.expect(d.is_dirty());
    try testing.expectEqual(@as(u64, 1), d.generation);
    d.mark();
    try testing.expectEqual(@as(u64, 2), d.generation);
}

test "Dirty: clear_on_save cleans it and remembers the saved signature" {
    var d = Dirty{};
    d.mark();
    d.clear_on_save(42);
    try testing.expect(!d.is_dirty());
    try testing.expect(!d.observe(42));
    try testing.expect(!d.is_dirty());
}

test "Dirty: a signature change marks dirty" {
    var d = Dirty{};
    d.clear_on_save(1);
    try testing.expect(d.observe(2));
    try testing.expect(d.is_dirty());
    try testing.expectEqual(@as(u64, 1), d.generation);
}

test "Dirty: a no-op change does not mark dirty or bump the generation" {
    var d = Dirty{};
    d.clear_on_save(7);
    try testing.expect(!d.observe(7));
    try testing.expect(!d.observe(7));
    try testing.expect(!d.is_dirty());
    try testing.expectEqual(@as(u64, 0), d.generation);
}

test "Dirty: edit then undo back to the saved signature stays dirty until a save" {
    var d = Dirty{};
    d.clear_on_save(7);
    _ = d.observe(8);
    _ = d.observe(7);
    try testing.expect(d.is_dirty());
    d.clear_on_save(7);
    try testing.expect(!d.is_dirty());
}

test "Dirty: rebase adopts a signature without changing the flag" {
    var d = Dirty{};
    d.mark();
    d.rebase(5);
    try testing.expect(d.is_dirty());
    try testing.expect(!d.observe(5));
    var clean = Dirty{};
    clean.rebase(5);
    try testing.expect(!clean.is_dirty());
}

test "decide: Save, Don't save and Cancel" {
    try testing.expectEqual(Step.save, decide(.yes));
    try testing.expectEqual(Step.proceed, decide(.no));
    try testing.expectEqual(Step.cancel, decide(.cancel));
}

test "afterSave: proceeds only when the save left nothing unsaved" {
    var d = Dirty{};
    d.mark();
    try testing.expectEqual(Step.cancel, afterSave(&d));
    d.clear_on_save(1);
    try testing.expectEqual(Step.proceed, afterSave(&d));
}

test "needsPrompt: only when dirty" {
    var d = Dirty{};
    try testing.expect(!needsPrompt(&d));
    d.mark();
    try testing.expect(needsPrompt(&d));
}
