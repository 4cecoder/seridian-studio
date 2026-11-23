// Translated to Zig from soundcraft/crates/engine/src/lib.rs (Copyright (c) 2026 ArtCraft Team and the SoundCraft contributors, MIT OR Apache-2.0). Modified by Seridian.
//! The command executor: the `Engine` half of SoundCraft's `lib.rs`. It holds
//! the current document snapshot and its history, and runs a registered command
//! (see `command.zig`) with the Rust rules: the disabled check that a named
//! target waives, the recording gate, copy-on-write snapshots, undo/redo with
//! the edit mode kept, merge-key gesture coalescing, a bounded command journal,
//! and rollback when a command fails.
//!
//! The document is opaque here. The Seridian document type is not in this
//! library yet, so `Executor` is driven through a `DocumentOps` table (retain,
//! release, reference count, clone, and equality that ignores navigation) plus
//! two hooks, `keep_edit_mode` and `remember_selection`. The document layer
//! supplies the query vtable that `command.Context` uses; its `ptr` is the
//! `*Executor`, so a query reaches the document with `documentPtr()`.
//!
//! Errors and rollback. Zig has no panics to catch, so a command reports failure
//! by returning an error. On any error return the executor restores the document
//! snapshot taken before the command, plus the side effects (clipboard, messages,
//! transport requests and last selection). This is wider than the Rust code,
//! whose error path restores only the document; the Rust panic path restored
//! the side effects too, and the Zig port uses that rule for every error.
//!
//! Threading: control thread only. The journal, history and message list
//! allocate, so none of this runs on the audio thread.

const std = @import("std");
const command = @import("command.zig");

/// Upper bound on journaled commands, so a long session cannot grow memory without limit.
pub const MAX_JOURNAL_ENTRIES: usize = 10_000;
/// Upper bound on a single journaled entry's params (serialized), so junk fields from MCP or the
/// control channel cannot keep a huge blob alive for the life of the process.
pub const MAX_JOURNAL_ENTRY_BYTES: usize = 64 * 1024;
/// Most undo steps kept before the oldest is dropped.
pub const HISTORY_LIMIT: usize = 200;

const MAX_MESSAGES: usize = 100;
const TRUNCATED_MARKER = "{\"__truncated__\":true}";
const FAILURE_ID_CAP: usize = 128;
const FAILURE_DETAIL_CAP: usize = 512;

/// Commands that replace the session or quit; they wait while a take is recorded.
const BLOCKED_WHILE_RECORDING = [_][]const u8{ "session.new", "session.open", "session.close", "session.revert", "app.quit" };
/// Parameter keys that name explicit targets. A command that names one does not need a selection.
const TARGET_KEYS = [_][]const u8{ "track", "tracks", "clip", "clips", "sources", "start", "end", "at" };

/// Errors `Executor` returns. Mirrors the Rust `EngineError` variants. The message
/// detail is kept in `Executor.lastFailure()` because Zig error values carry no payload.
pub const EngineError = error{
    UnknownCommand,
    Disabled,
    BadParams,
    NotFound,
    Io,
    Unsupported,
    Internal,
    OutOfMemory,
};

/// Errors from operations that only allocate (COW clones, history, journal, messages).
pub const AllocError = std.mem.Allocator.Error;

/// An opaque snapshot of the document. Identity is the pointer: two handles are the
/// same snapshot exactly when `ptr` is equal. The reference count and the destroy
/// callback live behind `DocumentOps`.
pub const Document = struct {
    ptr: *anyopaque,

    pub fn sameIdentity(a: Document, b: Document) bool {
        return a.ptr == b.ptr;
    }
};

/// The operations the document layer provides for its snapshot type.
pub const DocumentOps = struct {
    /// Adds one reference to `ptr`.
    retain: *const fn (ptr: *anyopaque) void,
    /// Drops one reference; the snapshot is destroyed when the count reaches zero.
    release: *const fn (ptr: *anyopaque) void,
    /// Current number of references (Arc::strong_count).
    ref_count: *const fn (ptr: *anyopaque) usize,
    /// A deep copy with one reference (the copy-on-write step, Rust `Arc::make_mut`).
    clone: *const fn (ptr: *anyopaque, gpa: std.mem.Allocator) AllocError!*anyopaque,
    /// Equal apart from navigation (selection, playhead, zoom). Used for the saved state
    /// (`is_dirty`), as Rust `same_document` does.
    same: *const fn (a: *anyopaque, b: *anyopaque) bool,
};

/// Wiring that the document layer supplies to an executor.
pub const Config = struct {
    /// Looks up a registered command by id.
    find: *const fn (id: []const u8) ?*const command.CommandSpec,
    /// Read-only queries for `command.Context`. Each function gets `ptr` = the `*Executor`.
    query: *const command.Context.VTable,
    ops: *const DocumentOps,
    /// Rust `keep_edit_mode`: after undo or redo, copy the edit mode and its flags from
    /// `from` (the document before the step) into the current document, copy-on-write.
    keep_edit_mode: *const fn (exec: *Executor, from: *anyopaque) AllocError!void,
    /// Rust `remember_selection`: when the selection changed since `before`, record the
    /// old one with `setLastSelection`.
    remember_selection: *const fn (exec: *Executor, before: *anyopaque) AllocError!void,
    journal_capacity: usize = MAX_JOURNAL_ENTRIES,
    history_limit: usize = HISTORY_LIMIT,
};

/// Clipboard placeholder. The Rust clipboard holds per-track clips, which the model
/// library will define. Restore here is a value copy, so a real clipboard must supply
/// its own clone and deinit (see the translation report).
pub const Clipboard = struct {
    length: i64 = 0,
};

/// Transport status reported back by the host.
pub const TransportStatus = struct {
    playing: bool = false,
    recording: bool = false,
    position: i64 = 0,
};

/// Requests for the transport and audio engine, drained by the host each frame.
pub const TransportRequest = union(enum) {
    reset_session,
    play,
    stop,
    toggle_play,
    record,
    locate: i64,
    play_selection,
    pause,
    half_speed,
    scrub: i64,
    all_notes_off,
};

/// The edit selection before the last change (Rust `last_selection`). Owns `tracks`.
pub const LastSelection = struct {
    range: command.Range,
    tracks: []u64,
};

/// One undo step: the label and the snapshot from before the change. Owns both.
pub const HistoryEntry = struct {
    label: []u8,
    doc: Document,
};

/// A journal entry. Owns both slices. Params are kept as serialized JSON, so a
/// journal slot holds a fixed-size record rather than a live `std.json.Value` tree.
pub const JournalEntry = struct {
    id: []u8,
    params: []u8,

    fn free(self: JournalEntry, gpa: std.mem.Allocator) void {
        gpa.free(self.id);
        gpa.free(self.params);
    }
};

/// A borrowed view of a journal entry, oldest first.
pub const JournalView = struct {
    id: []const u8,
    params: []const u8,
};

/// Detail of the last failed `execute`. Slices point into the executor and stay valid
/// until the next failure.
pub const Failure = struct {
    err: EngineError,
    id: []const u8,
    detail: []const u8,
};

/// Side effects of a command: everything a failed command must put back. Owned.
const Effects = struct {
    clipboard: Clipboard,
    messages: std.ArrayList([]u8),
    transport_requests: std.ArrayList(TransportRequest),
    last_selection: ?LastSelection,

    fn capture(ex: *const Executor) AllocError!Effects {
        const gpa = ex.gpa;
        var messages: std.ArrayList([]u8) = .empty;
        errdefer freeMessages(gpa, &messages);
        try messages.ensureTotalCapacity(gpa, ex.messages.items.len);
        for (ex.messages.items) |m| messages.appendAssumeCapacity(try gpa.dupe(u8, m));

        var transport: std.ArrayList(TransportRequest) = .empty;
        errdefer transport.deinit(gpa);
        try transport.appendSlice(gpa, ex.transport_requests.items);

        var last: ?LastSelection = null;
        if (ex.last_selection) |ls| {
            last = .{ .range = ls.range, .tracks = try gpa.dupe(u64, ls.tracks) };
        }
        return .{
            .clipboard = ex.clipboard,
            .messages = messages,
            .transport_requests = transport,
            .last_selection = last,
        };
    }

    /// Frees the snapshot without restoring it (the command succeeded).
    fn deinit(self: *Effects, gpa: std.mem.Allocator) void {
        freeMessages(gpa, &self.messages);
        self.transport_requests.deinit(gpa);
        if (self.last_selection) |ls| gpa.free(ls.tracks);
    }

    /// Moves the snapshot back into `ex`. Allocates nothing, so it cannot fail.
    /// The snapshot is consumed.
    fn restore(self: *Effects, ex: *Executor) void {
        const gpa = ex.gpa;
        freeMessages(gpa, &ex.messages);
        ex.messages = self.messages;
        ex.clipboard = self.clipboard;
        ex.transport_requests.deinit(gpa);
        ex.transport_requests = self.transport_requests;
        if (ex.last_selection) |ls| gpa.free(ls.tracks);
        ex.last_selection = self.last_selection;
    }
};

fn freeMessages(gpa: std.mem.Allocator, list: *std.ArrayList([]u8)) void {
    for (list.items) |m| gpa.free(m);
    list.deinit(gpa);
}

fn namesTargets(params: std.json.Value) bool {
    const o = switch (params) {
        .object => |o| o,
        else => return false,
    };
    for (TARGET_KEYS) |k| {
        if (o.get(k) != null) return true;
    }
    return false;
}

fn fromCommand(err: command.CommandError) EngineError {
    return switch (err) {
        error.BadParams => error.BadParams,
        error.Internal => error.Internal,
        error.OutOfMemory => error.OutOfMemory,
    };
}

fn optSliceEql(a: ?[]const u8, b: ?[]const u8) bool {
    if (a == null or b == null) return a == null and b == null;
    return std.mem.eql(u8, a.?, b.?);
}

/// The engine state: the document, its history, the side effects, the journal and the
/// merge gesture. Must be deinitialized. Control thread only.
pub const Executor = struct {
    gpa: std.mem.Allocator,
    config: Config,
    /// The current document snapshot. Owned: one reference.
    doc: Document,
    /// The document as last opened or saved, for `isDirty`. Owned: one reference.
    saved: Document,
    undo_stack: std.ArrayList(HistoryEntry) = .empty,
    redo_stack: std.ArrayList(HistoryEntry) = .empty,
    history_limit: usize,
    clipboard: Clipboard = .{},
    transport_requests: std.ArrayList(TransportRequest) = .empty,
    transport: TransportStatus = .{},
    /// Messages for the UI status line and agents, oldest first, at most 100.
    messages: std.ArrayList([]u8) = .empty,
    last_selection: ?LastSelection = null,

    journal_buf: []JournalEntry,
    journal_head: usize = 0,
    journal_len: usize = 0,
    /// Fixed scratch for bounded serialization of journal params (MAX + 1 bytes).
    journal_scratch: []u8,

    /// Bumps on every document change except zoom (UI caches key on it).
    revision: u64 = 1,
    dirty: bool = false,
    /// Cache for `isDirty`: the revision it was computed for and the answer.
    dirty_at_rev: u64 = 0,
    dirty_at_val: bool = false,

    /// Gesture key for undo coalescing (see `executeMerged`). Owned.
    merge_key: ?[]u8 = null,
    /// The key every merged gesture takes while held (see `holdMerge`). Owned.
    merge_hold: ?[]u8 = null,

    /// Message from the last `BadParams` or `Internal` failure, reused for every command.
    diag: command.Diagnostic = .{},
    failure_err: ?EngineError = null,
    failure_id_buf: [FAILURE_ID_CAP]u8 = undefined,
    failure_id_len: usize = 0,
    failure_detail_buf: [FAILURE_DETAIL_CAP]u8 = undefined,
    failure_detail_len: usize = 0,

    /// Takes ownership of `initial` (one reference). The executor retains it again for
    /// `saved`, as Rust `Engine::new` does.
    pub fn init(gpa: std.mem.Allocator, config: Config, initial: Document) AllocError!Executor {
        std.debug.assert(config.journal_capacity > 0);
        const journal_buf = try gpa.alloc(JournalEntry, config.journal_capacity);
        errdefer gpa.free(journal_buf);
        @memset(journal_buf, JournalEntry{ .id = &.{}, .params = &.{} });
        const scratch = try gpa.alloc(u8, MAX_JOURNAL_ENTRY_BYTES + 1);
        config.ops.retain(initial.ptr);
        return .{
            .gpa = gpa,
            .config = config,
            .doc = initial,
            .saved = initial,
            .history_limit = config.history_limit,
            .journal_buf = journal_buf,
            .journal_scratch = scratch,
        };
    }

    pub fn deinit(self: *Executor) void {
        const ops = self.config.ops;
        ops.release(self.doc.ptr);
        ops.release(self.saved.ptr);
        for (self.undo_stack.items) |h| self.dropHistory(h);
        self.undo_stack.deinit(self.gpa);
        for (self.redo_stack.items) |h| self.dropHistory(h);
        self.redo_stack.deinit(self.gpa);
        self.transport_requests.deinit(self.gpa);
        freeMessages(self.gpa, &self.messages);
        if (self.last_selection) |ls| self.gpa.free(ls.tracks);
        self.clearMergeKey();
        if (self.merge_hold) |k| self.gpa.free(k);
        for (0..self.journal_len) |i| {
            self.journal_buf[(self.journal_head + i) % self.journal_buf.len].free(self.gpa);
        }
        self.gpa.free(self.journal_buf);
        self.gpa.free(self.journal_scratch);
        self.* = undefined;
    }

    // ---- document access ----------------------------------------------------------

    /// The current snapshot's pointer, for read-only queries.
    pub fn documentPtr(self: *const Executor) *anyopaque {
        return self.doc.ptr;
    }

    /// Makes the current snapshot writable: clones it first if it is shared (Rust
    /// `Arc::make_mut`). The returned pointer is valid until the next call that may
    /// clone. Does not bump the revision.
    pub fn cowDocument(self: *Executor) AllocError!*anyopaque {
        const ops = self.config.ops;
        if (ops.ref_count(self.doc.ptr) > 1) {
            const fresh = try ops.clone(self.doc.ptr, self.gpa);
            ops.release(self.doc.ptr);
            self.doc = .{ .ptr = fresh };
        }
        return self.doc.ptr;
    }

    /// Writable access for a document change: the Rust `session_mut`. Bumps the
    /// revision and marks the session dirty.
    pub fn editDocument(self: *Executor) AllocError!*anyopaque {
        const p = try self.cowDocument();
        self.revision +%= 1;
        self.dirty = true;
        return p;
    }

    /// Writable access for zoom only: the Rust `zoom_mut`. Marks dirty, does not bump the revision.
    pub fn zoomDocument(self: *Executor) AllocError!*anyopaque {
        const p = try self.cowDocument();
        self.dirty = true;
        return p;
    }

    fn retainDocument(self: *Executor) Document {
        self.config.ops.retain(self.doc.ptr);
        return self.doc;
    }

    fn context(self: *Executor) command.Context {
        return .{
            .ptr = self,
            .vtable = self.config.query,
            .gpa = self.gpa,
            .diag = &self.diag,
        };
    }

    /// Whether the document changed since it was opened or saved. Selecting, locating and
    /// zooming do not count, and undoing back to the saved state makes it clean again.
    pub fn isDirty(self: *Executor) bool {
        if (!self.dirty) return false;
        if (self.dirty_at_rev == self.revision) return self.dirty_at_val;
        const d = if (Document.sameIdentity(self.saved, self.doc))
            false
        else
            !self.config.ops.same(self.saved.ptr, self.doc.ptr);
        self.dirty_at_rev = self.revision;
        self.dirty_at_val = d;
        return d;
    }

    /// Marks the current document as the saved one.
    pub fn markClean(self: *Executor) void {
        self.config.ops.retain(self.doc.ptr);
        self.config.ops.release(self.saved.ptr);
        self.saved = self.doc;
        self.dirty = false;
    }

    /// Replaces the whole document (open or new) and clears history. Takes ownership of
    /// `new` (one reference). `selection_start` seeds the playhead, as the Rust code does.
    pub fn replaceDocument(self: *Executor, new: Document, selection_start: i64) AllocError!void {
        self.transport_requests.clearRetainingCapacity();
        self.transport_requests.append(self.gpa, .reset_session) catch |err| {
            self.config.ops.release(new.ptr);
            return err;
        };
        self.transport = .{ .position = @max(selection_start, 0) };
        self.clearUndo();
        self.clearRedo();
        if (self.last_selection) |ls| self.gpa.free(ls.tracks);
        self.last_selection = null;

        const ops = self.config.ops;
        ops.release(self.doc.ptr);
        self.doc = new;
        ops.retain(new.ptr);
        ops.release(self.saved.ptr);
        self.saved = new;
        self.revision +%= 1;
        self.dirty = false;
    }

    // ---- history ------------------------------------------------------------------

    pub fn canUndo(self: *const Executor) bool {
        return self.undo_stack.items.len != 0;
    }

    pub fn canRedo(self: *const Executor) bool {
        return self.redo_stack.items.len != 0;
    }

    pub fn undoCount(self: *const Executor) usize {
        return self.undo_stack.items.len;
    }

    pub fn redoCount(self: *const Executor) usize {
        return self.redo_stack.items.len;
    }

    /// The label of the next undo step, if any.
    pub fn undoLabel(self: *const Executor) ?[]const u8 {
        if (self.undo_stack.items.len == 0) return null;
        return self.undo_stack.items[self.undo_stack.items.len - 1].label;
    }

    /// The label of the next redo step, if any.
    pub fn redoLabel(self: *const Executor) ?[]const u8 {
        if (self.redo_stack.items.len == 0) return null;
        return self.redo_stack.items[self.redo_stack.items.len - 1].label;
    }

    /// Steps the document back. Returns false when there is nothing to undo.
    pub fn undo(self: *Executor) AllocError!bool {
        return self.stepHistory(&self.undo_stack, &self.redo_stack);
    }

    /// Steps the document forward. Returns false when there is nothing to redo.
    pub fn redo(self: *Executor) AllocError!bool {
        return self.stepHistory(&self.redo_stack, &self.undo_stack);
    }

    /// Moves the top step of `from` onto `to`, swapping the current document with the step's
    /// snapshot. `to` gets the document as it was before the step.
    fn stepHistory(self: *Executor, from: *std.ArrayList(HistoryEntry), to: *std.ArrayList(HistoryEntry)) AllocError!bool {
        if (from.items.len == 0) return false;
        try to.ensureUnusedCapacity(self.gpa, 1);
        const h = from.pop().?;
        const cur = self.doc;
        // self.doc takes its own reference, so `h.doc` survives a copy-on-write inside the hook.
        self.config.ops.retain(h.doc.ptr);
        self.doc = h.doc;
        self.config.keep_edit_mode(self, cur.ptr) catch |err| {
            self.config.ops.release(self.doc.ptr);
            self.doc = cur;
            from.appendAssumeCapacity(h);
            return err;
        };
        // The history's reference is no longer needed; self.doc keeps its own.
        self.config.ops.release(h.doc.ptr);
        to.appendAssumeCapacity(.{ .label = h.label, .doc = cur });
        self.revision +%= 1;
        self.dirty = true;
        return true;
    }

    /// Records an undo point by hand (for gestures the UI commits itself). Does nothing when
    /// `before` is the current snapshot. Borrows `before`; the history takes its own reference.
    /// Clears redo. Keeps at most `history_limit` steps.
    pub fn pushUndo(self: *Executor, label: []const u8, before: Document) AllocError!void {
        if (Document.sameIdentity(before, self.doc)) return;
        try self.undo_stack.ensureUnusedCapacity(self.gpa, 1);
        const owned = try self.gpa.dupe(u8, label);
        self.clearRedo();
        self.config.ops.retain(before.ptr);
        self.undo_stack.appendAssumeCapacity(.{ .label = owned, .doc = before });
        while (self.undo_stack.items.len > self.history_limit) {
            self.dropHistory(self.undo_stack.orderedRemove(0));
        }
    }

    fn dropHistory(self: *Executor, h: HistoryEntry) void {
        self.gpa.free(h.label);
        self.config.ops.release(h.doc.ptr);
    }

    fn clearUndo(self: *Executor) void {
        for (self.undo_stack.items) |h| self.dropHistory(h);
        self.undo_stack.clearRetainingCapacity();
    }

    fn clearRedo(self: *Executor) void {
        for (self.redo_stack.items) |h| self.dropHistory(h);
        self.redo_stack.clearRetainingCapacity();
    }

    // ---- side effects -------------------------------------------------------------

    /// Records the edit selection before the last change (Rust `last_selection`).
    pub fn setLastSelection(self: *Executor, range: command.Range, tracks: []const u64) AllocError!void {
        const owned = try self.gpa.dupe(u64, tracks);
        if (self.last_selection) |old| self.gpa.free(old.tracks);
        self.last_selection = .{ .range = range, .tracks = owned };
    }

    /// Appends a message for the UI status line. Keeps the newest 100.
    pub fn message(self: *Executor, m: []const u8) AllocError!void {
        const owned = try self.gpa.dupe(u8, m);
        errdefer self.gpa.free(owned);
        try self.messages.append(self.gpa, owned);
        if (self.messages.items.len > MAX_MESSAGES) {
            self.gpa.free(self.messages.orderedRemove(0));
        }
    }

    /// Queues a transport request for the host to drain.
    pub fn requestTransport(self: *Executor, req: TransportRequest) AllocError!void {
        try self.transport_requests.append(self.gpa, req);
    }

    /// The failure of the last `execute` that failed, if any.
    pub fn lastFailure(self: *const Executor) ?Failure {
        const err = self.failure_err orelse return null;
        return .{
            .err = err,
            .id = self.failure_id_buf[0..self.failure_id_len],
            .detail = self.failure_detail_buf[0..self.failure_detail_len],
        };
    }

    fn fail(self: *Executor, err: EngineError, id: []const u8, detail: []const u8) EngineError {
        const id_n = @min(id.len, FAILURE_ID_CAP);
        @memcpy(self.failure_id_buf[0..id_n], id[0..id_n]);
        self.failure_id_len = id_n;
        const detail_n = @min(detail.len, FAILURE_DETAIL_CAP);
        @memcpy(self.failure_detail_buf[0..detail_n], detail[0..detail_n]);
        self.failure_detail_len = detail_n;
        self.failure_err = err;
        return err;
    }

    // ---- gestures -----------------------------------------------------------------

    /// While `key` is held, every `executeMerged` gesture takes it instead of its own, so they
    /// all join one undo step (an automation pass and whatever is dragged during it).
    pub fn holdMerge(self: *Executor, key: ?[]const u8) AllocError!void {
        if (optSliceEql(self.merge_hold, key)) return;
        const fresh: ?[]u8 = if (key) |k| try self.gpa.dupe(u8, k) else null;
        if (self.merge_hold) |old| self.gpa.free(old);
        self.merge_hold = fresh;
    }

    /// The gesture `executeMerged` is continuing, if any.
    pub fn mergeKey(self: *const Executor) ?[]const u8 {
        return self.merge_key;
    }

    /// Ends a gesture started with `executeMerged`.
    pub fn endMerge(self: *Executor) void {
        self.clearMergeKey();
    }

    fn clearMergeKey(self: *Executor) void {
        if (self.merge_key) |k| self.gpa.free(k);
        self.merge_key = null;
    }

    /// Execute as part of a continuous gesture (fader drag, knob turn, slider). Consecutive calls
    /// with the same key collapse into one undo step.
    pub fn executeMerged(self: *Executor, id: []const u8, params: std.json.Value, key: []const u8) EngineError!std.json.Value {
        const effective: []const u8 = self.merge_hold orelse key;
        const continuing = if (self.merge_key) |mk| std.mem.eql(u8, mk, effective) else false;
        const before_len = self.undo_stack.items.len;
        // The key is copied before the command runs, so the only allocation left after it is
        // none.
        const next_key = try self.gpa.dupe(u8, effective);
        errdefer self.gpa.free(next_key);

        // The step pushed for a continuing tick is dropped again below, so it must not trim the
        // oldest entry first when the history is full.
        const limit = self.history_limit;
        if (continuing and before_len > 0) {
            self.history_limit = @max(limit, before_len +| 1);
        }
        const r = self.execute(id, params);
        self.history_limit = limit;
        const value = try r;
        if (continuing and self.undo_stack.items.len == before_len + 1 and before_len > 0) {
            // Drop the step just pushed; the earlier one still holds the pre-gesture document.
            self.dropHistory(self.undo_stack.pop().?);
        }
        self.clearMergeKey();
        self.merge_key = next_key;
        return value;
    }

    // ---- execution ----------------------------------------------------------------

    fn blockedWhileRecording(self: *const Executor, id: []const u8) bool {
        if (!self.transport.recording) return false;
        for (BLOCKED_WHILE_RECORDING) |b| {
            if (std.mem.eql(u8, b, id)) return true;
        }
        return false;
    }

    /// Runs a command by id. Returns the command's result, or the error after the document
    /// and side effects have been restored.
    pub fn execute(self: *Executor, id: []const u8, params: std.json.Value) EngineError!std.json.Value {
        const spec = self.config.find(id) orelse return self.fail(error.UnknownCommand, id, "");
        if (self.blockedWhileRecording(id)) return self.fail(error.Disabled, id, "stop recording first");
        if (spec.enabled(self.context())) |reason| {
            // A call that names its targets (tracks, clips, a range) does not need a selection;
            // the command itself validates them.
            if (!namesTargets(params)) return self.fail(error.Disabled, id, reason);
        }
        if (spec.view) return self.executeView(spec, id, params);

        const before = self.retainDocument();
        const was_dirty = self.dirty;
        var effects = Effects.capture(self) catch |err| {
            self.config.ops.release(before.ptr);
            return self.fail(err, id, "");
        };
        self.diag.len = 0;
        const result = spec.run(self.context(), params);
        // Only a change to the document ends a gesture, so Stop doesn't split the pass it ends.
        if (!Document.sameIdentity(before, self.doc)) self.clearMergeKey();

        if (result) |value| {
            self.commitSuccess(spec, id, params, before) catch |err| {
                self.rollback(before, was_dirty, &effects);
                return self.fail(err, id, "");
            };
            self.config.ops.release(before.ptr);
            effects.deinit(self.gpa);
            return value;
        } else |err| {
            const detail: []const u8 = if (err == error.BadParams) self.diag.message() else "";
            self.rollback(before, was_dirty, &effects);
            return self.fail(fromCommand(err), id, detail);
        }
    }

    /// The fallible half of a successful command. Every step that can fail runs before the
    /// one that commits, and `before` is only borrowed.
    fn commitSuccess(self: *Executor, spec: *const command.CommandSpec, id: []const u8, params: std.json.Value, before: Document) AllocError!void {
        var journal_entry: ?JournalEntry = if (spec.journal) try self.makeJournalEntry(id, params) else null;
        errdefer if (journal_entry) |e| e.free(self.gpa);

        try self.config.remember_selection(self, before.ptr);
        if (spec.undoable) try self.pushUndo(spec.label, before);
        if (journal_entry) |e| {
            self.insertJournal(e);
            journal_entry = null;
        }
    }

    /// Restores the document (if it changed) and the side effects. Releases `before`.
    fn rollback(self: *Executor, before: Document, was_dirty: bool, effects: *Effects) void {
        if (Document.sameIdentity(before, self.doc)) {
            self.config.ops.release(before.ptr);
        } else {
            self.config.ops.release(self.doc.ptr);
            self.doc = before;
            self.revision +%= 1;
            self.dirty = was_dirty;
        }
        effects.restore(self);
    }

    /// View commands only move the zoom. A failed view restores the snapshot taken before it
    /// and the side effects. The revision is left alone, as in the Rust `execute_view`.
    fn executeView(self: *Executor, spec: *const command.CommandSpec, id: []const u8, params: std.json.Value) EngineError!std.json.Value {
        const before = self.retainDocument();
        var effects = Effects.capture(self) catch |err| {
            self.config.ops.release(before.ptr);
            return self.fail(err, id, "");
        };
        self.diag.len = 0;
        const result = spec.run(self.context(), params);
        if (result) |value| {
            self.config.ops.release(before.ptr);
            effects.deinit(self.gpa);
            return value;
        } else |err| {
            if (Document.sameIdentity(before, self.doc)) {
                self.config.ops.release(before.ptr);
            } else {
                self.config.ops.release(self.doc.ptr);
                self.doc = before;
            }
            effects.restore(self);
            const detail: []const u8 = if (err == error.BadParams) self.diag.message() else "";
            return self.fail(fromCommand(err), id, detail);
        }
    }

    /// Convenience: execute with `{}` params.
    pub fn run(self: *Executor, id: []const u8) EngineError!std.json.Value {
        const empty: std.json.Value = .{ .object = .empty };
        return self.execute(id, empty);
    }

    // ---- journal ------------------------------------------------------------------

    /// Appends a journaled command. Its params are clamped to `MAX_JOURNAL_ENTRY_BYTES`, and
    /// the ring keeps at most `journal_capacity` entries, dropping the oldest.
    pub fn journalAppend(self: *Executor, id: []const u8, params: std.json.Value) AllocError!void {
        const entry = try self.makeJournalEntry(id, params);
        self.insertJournal(entry);
    }

    fn makeJournalEntry(self: *Executor, id: []const u8, params: std.json.Value) AllocError!JournalEntry {
        const bytes = try self.journalParams(params);
        errdefer self.gpa.free(bytes);
        const id_owned = try self.gpa.dupe(u8, id);
        return .{ .id = id_owned, .params = bytes };
    }

    /// Infallible: the caller has already allocated the entry. Overwrites the oldest slot
    /// when the ring is full.
    fn insertJournal(self: *Executor, entry: JournalEntry) void {
        const cap = self.journal_buf.len;
        if (self.journal_len == cap) {
            self.journal_buf[self.journal_head].free(self.gpa);
            self.journal_buf[self.journal_head] = entry;
            self.journal_head = (self.journal_head + 1) % cap;
        } else {
            self.journal_buf[(self.journal_head + self.journal_len) % cap] = entry;
            self.journal_len += 1;
        }
    }

    /// The params to keep in the journal: the serialized value when it fits within
    /// `MAX_JOURNAL_ENTRY_BYTES`, or the truncation marker when it does not. Serialization
    /// goes into a fixed buffer and stops at the cap, so an oversized value costs at most the
    /// cap.
    pub fn journalParams(self: *Executor, params: std.json.Value) AllocError![]u8 {
        var w = std.Io.Writer.fixed(self.journal_scratch);
        std.json.Stringify.value(params, .{}, &w) catch return self.gpa.dupe(u8, TRUNCATED_MARKER);
        const bytes = w.buffered();
        if (bytes.len > MAX_JOURNAL_ENTRY_BYTES) return self.gpa.dupe(u8, TRUNCATED_MARKER);
        return self.gpa.dupe(u8, bytes);
    }

    pub fn journalLen(self: *const Executor) usize {
        return self.journal_len;
    }

    /// The journal entry at `i`, oldest first. Asserts `i < journalLen()`.
    pub fn journalAt(self: *const Executor, i: usize) JournalView {
        std.debug.assert(i < self.journal_len);
        const e = self.journal_buf[(self.journal_head + i) % self.journal_buf.len];
        return .{ .id = e.id, .params = e.params };
    }
};

// ============================================================================
// Tests. The Rust tests in lib.rs (journal_tests, merge_tests, dirty_tests,
// panic_tests) are ported below against a fake document and fake commands.
// ============================================================================

const testing = std.testing;

const MAX_FAKE_TRACKS = 4;

const FakeTrack = struct {
    name: []const u8 = "",
    volume_db: f32 = 0,
    pan: f32 = 0,
    muted: bool = false,
    selected: bool = false,
};

/// A document standing in for the session: a few tracks plus navigation state. `same` ignores
/// navigation (selection, playhead, zoom and scroll), as Rust `same_document` does.
const FakeDoc = struct {
    gpa: std.mem.Allocator,
    refs: usize = 1,
    tracks: [MAX_FAKE_TRACKS]FakeTrack = undefined,
    track_count: usize = 0,
    edit_mode: u8 = 0,
    snap: bool = false,
    selection: command.Range = command.Range.point(0),
    playhead: i64 = 0,
    zoom: i64 = 0,
    scroll: i64 = 0,

    fn create(gpa: std.mem.Allocator, demo: bool) AllocError!*FakeDoc {
        const d = try gpa.create(FakeDoc);
        d.* = .{ .gpa = gpa };
        if (demo) _ = addFakeTrack(d, "Kick");
        return d;
    }

    fn addFakeTrack(d: *FakeDoc, name: []const u8) usize {
        d.tracks[d.track_count] = .{ .name = name };
        d.track_count += 1;
        return d.track_count - 1;
    }
};

fn fromPtr(ptr: *anyopaque) *FakeDoc {
    return @ptrCast(@alignCast(ptr));
}

fn execOf(ptr: *anyopaque) *Executor {
    return @ptrCast(@alignCast(ptr));
}

/// The current document of the executor behind a command or query context pointer.
fn currentDoc(ptr: *anyopaque) *FakeDoc {
    return fromPtr(execOf(ptr).documentPtr());
}

fn fakeRetain(ptr: *anyopaque) void {
    fromPtr(ptr).refs += 1;
}

fn fakeRelease(ptr: *anyopaque) void {
    const d = fromPtr(ptr);
    d.refs -= 1;
    if (d.refs == 0) d.gpa.destroy(d);
}

fn fakeRefCount(ptr: *anyopaque) usize {
    return fromPtr(ptr).refs;
}

fn fakeClone(ptr: *anyopaque, gpa: std.mem.Allocator) AllocError!*anyopaque {
    const src = fromPtr(ptr);
    const d = try gpa.create(FakeDoc);
    d.* = src.*;
    d.gpa = gpa;
    d.refs = 1;
    return d;
}

fn fakeSame(a: *anyopaque, b: *anyopaque) bool {
    const x = fromPtr(a);
    const y = fromPtr(b);
    if (x.track_count != y.track_count or x.edit_mode != y.edit_mode or x.snap != y.snap) return false;
    for (x.tracks[0..x.track_count], y.tracks[0..y.track_count]) |p, q| {
        if (!std.mem.eql(u8, p.name, q.name)) return false;
        if (p.volume_db != q.volume_db or p.pan != q.pan or p.muted != q.muted) return false;
    }
    return true;
}

const fake_ops: DocumentOps = .{
    .retain = fakeRetain,
    .release = fakeRelease,
    .ref_count = fakeRefCount,
    .clone = fakeClone,
    .same = fakeSame,
};

fn keepEditMode(ex: *Executor, from: *anyopaque) AllocError!void {
    const src = fromPtr(from);
    const cur = fromPtr(ex.documentPtr());
    if (cur.edit_mode == src.edit_mode and cur.snap == src.snap) return;
    const w = fromPtr(try ex.cowDocument());
    w.edit_mode = src.edit_mode;
    w.snap = src.snap;
}

fn rememberSelection(ex: *Executor, before: *anyopaque) AllocError!void {
    const old = fromPtr(before);
    const new = fromPtr(ex.documentPtr());
    var same_tracks = true;
    for (old.tracks[0..old.track_count], new.tracks[0..new.track_count]) |p, q| {
        if (p.selected != q.selected) same_tracks = false;
    }
    if (old.track_count != new.track_count) same_tracks = false;
    if (std.meta.eql(old.selection, new.selection) and same_tracks) return;
    var ids: [MAX_FAKE_TRACKS]u64 = undefined;
    var n: usize = 0;
    for (old.tracks[0..old.track_count], 0..) |t, i| {
        if (t.selected) {
            ids[n] = @intCast(i);
            n += 1;
        }
    }
    try ex.setLastSelection(old.selection, ids[0..n]);
}

// ---- fake queries (the command.Context vtable) ----

fn qTrackCount(ptr: *anyopaque) usize {
    return currentDoc(ptr).track_count;
}

fn qSelectedTrackCount(ptr: *anyopaque) usize {
    var n: usize = 0;
    for (currentDoc(ptr).tracks[0..currentDoc(ptr).track_count]) |t| {
        if (t.selected) n += 1;
    }
    return n;
}

fn qZero(_: *anyopaque) usize {
    return 0;
}

fn qSelectionEmpty(ptr: *anyopaque) bool {
    return currentDoc(ptr).selection.isEmpty();
}

fn qSelection(ptr: *anyopaque) command.Range {
    return currentDoc(ptr).selection;
}

fn qCanUndo(ptr: *anyopaque) bool {
    return execOf(ptr).canUndo();
}

fn qCanRedo(ptr: *anyopaque) bool {
    return execOf(ptr).canRedo();
}

fn qTrackExists(ptr: *anyopaque, id: command.TrackId) bool {
    return id < currentDoc(ptr).track_count;
}

fn qTrackIdByName(ptr: *anyopaque, name: []const u8) ?command.TrackId {
    const d = currentDoc(ptr);
    for (d.tracks[0..d.track_count], 0..) |t, i| {
        if (std.mem.eql(u8, t.name, name)) return @intCast(i);
    }
    return null;
}

fn qTargetTracks(ptr: *anyopaque, gpa: std.mem.Allocator) AllocError!std.ArrayList(command.TrackId) {
    const d = currentDoc(ptr);
    var out: std.ArrayList(command.TrackId) = .empty;
    errdefer out.deinit(gpa);
    for (d.tracks[0..d.track_count], 0..) |t, i| {
        if (t.selected) try out.append(gpa, @intCast(i));
    }
    return out;
}

fn qNoIds(_: *anyopaque, _: std.mem.Allocator) AllocError!std.ArrayList(command.ClipId) {
    return .empty;
}

fn qParsePosition(_: *anyopaque, text: []const u8) ?i64 {
    return std.fmt.parseInt(i64, text, 10) catch null;
}

fn qSecondsToSamples(_: *anyopaque, seconds: f64) i64 {
    return @intFromFloat(@round(seconds * 48_000.0));
}

const fake_query: command.Context.VTable = .{
    .track_count = qTrackCount,
    .selected_track_count = qSelectedTrackCount,
    .selected_clip_count = qZero,
    .selection_is_empty = qSelectionEmpty,
    .selection = qSelection,
    .can_undo = qCanUndo,
    .can_redo = qCanRedo,
    .clipboard_track_count = qZero,
    .track_exists = qTrackExists,
    .track_id_by_name = qTrackIdByName,
    .target_tracks = qTargetTracks,
    .selected_clip_ids = qNoIds,
    .clips_in_selection = qNoIds,
    .parse_position = qParsePosition,
    .seconds_to_samples = qSecondsToSamples,
};

// ---- fake commands ----

fn paramValue(params: std.json.Value, key: []const u8) ?std.json.Value {
    return switch (params) {
        .object => |o| o.get(key),
        else => null,
    };
}

fn numberParam(params: std.json.Value, key: []const u8) ?f64 {
    const v = paramValue(params, key) orelse return null;
    return switch (v) {
        .integer => |i| @as(f64, @floatFromInt(i)),
        .float => |f| f,
        else => null,
    };
}

fn intParam(params: std.json.Value, key: []const u8) ?i64 {
    const v = paramValue(params, key) orelse return null;
    return switch (v) {
        .integer => |i| i,
        else => null,
    };
}

/// A track named by id (integer) or by name (string), as the commands accept it.
fn trackIndexOfValue(d: *const FakeDoc, v: std.json.Value) ?usize {
    switch (v) {
        .integer => |i| {
            if (i < 0) return null;
            const u: usize = @intCast(i);
            return if (u < d.track_count) u else null;
        },
        .string => |s| {
            for (d.tracks[0..d.track_count], 0..) |t, idx| {
                if (std.mem.eql(u8, t.name, s)) return idx;
            }
            return null;
        },
        else => return null,
    }
}

fn trackIndex(d: *const FakeDoc, params: std.json.Value) ?usize {
    const v = paramValue(params, "track") orelse return null;
    return trackIndexOfValue(d, v);
}

fn badParams(ctx: command.Context, id: []const u8, msg: []const u8) command.CommandError {
    ctx.diag.set("bad parameters for `{s}`: {s}", .{ id, msg });
    return error.BadParams;
}

/// Writable document for a command. Copy-on-write, so the revision and dirty flag move.
fn mutDoc(ptr: *anyopaque) command.CommandError!*FakeDoc {
    return fromPtr(try execOf(ptr).editDocument());
}

fn zoomDoc(ptr: *anyopaque) command.CommandError!*FakeDoc {
    return fromPtr(try execOf(ptr).zoomDocument());
}

fn mixVolume(ctx: command.Context, params: std.json.Value) command.CommandError!std.json.Value {
    const idx = trackIndex(currentDoc(ctx.ptr), params) orelse return badParams(ctx, "mix.volume", "`track` required");
    const db = numberParam(params, "db") orelse return badParams(ctx, "mix.volume", "`db` required");
    const w = try mutDoc(ctx.ptr);
    w.tracks[idx].volume_db = @floatCast(db);
    return .null;
}

fn mixPan(ctx: command.Context, params: std.json.Value) command.CommandError!std.json.Value {
    const idx = trackIndex(currentDoc(ctx.ptr), params) orelse return badParams(ctx, "mix.pan", "`track` required");
    const pan = numberParam(params, "pan") orelse return badParams(ctx, "mix.pan", "`pan` required");
    const w = try mutDoc(ctx.ptr);
    w.tracks[idx].pan = @floatCast(pan);
    return .null;
}

fn mixMute(ctx: command.Context, params: std.json.Value) command.CommandError!std.json.Value {
    const idx = trackIndex(currentDoc(ctx.ptr), params) orelse return badParams(ctx, "mix.mute", "`track` required");
    const w = try mutDoc(ctx.ptr);
    w.tracks[idx].muted = !w.tracks[idx].muted;
    return .null;
}

fn editMode(ctx: command.Context, params: std.json.Value) command.CommandError!std.json.Value {
    const mode = intParam(params, "mode") orelse return badParams(ctx, "edit.mode", "`mode` required");
    const w = try mutDoc(ctx.ptr);
    w.edit_mode = @intCast(mode);
    return .null;
}

fn editSelect(ctx: command.Context, params: std.json.Value) command.CommandError!std.json.Value {
    const start = intParam(params, "start") orelse 0;
    const end = intParam(params, "end") orelse start;
    const w = try mutDoc(ctx.ptr);
    w.selection = command.Range.new(start, end);
    for (&w.tracks) |*t| t.selected = false;
    if (paramValue(params, "tracks")) |v| switch (v) {
        .array => |arr| for (arr.items) |item| {
            if (trackIndexOfValue(w, item)) |idx| w.tracks[idx].selected = true;
        },
        else => {},
    };
    return .null;
}

fn editSelectNone(ctx: command.Context, _: std.json.Value) command.CommandError!std.json.Value {
    const w = try mutDoc(ctx.ptr);
    for (&w.tracks) |*t| t.selected = false;
    w.selection = command.Range.point(0);
    return .null;
}

fn transportLocate(ctx: command.Context, params: std.json.Value) command.CommandError!std.json.Value {
    const at = intParam(params, "at") orelse return badParams(ctx, "transport.locate", "`at` required");
    const w = try mutDoc(ctx.ptr);
    w.playhead = at;
    return .null;
}

fn transportStop(ctx: command.Context, _: std.json.Value) command.CommandError!std.json.Value {
    try execOf(ctx.ptr).requestTransport(.stop);
    return .null;
}

fn viewZoomIn(ctx: command.Context, _: std.json.Value) command.CommandError!std.json.Value {
    const w = try zoomDoc(ctx.ptr);
    w.zoom += 1;
    return .null;
}

fn viewScroll(ctx: command.Context, params: std.json.Value) command.CommandError!std.json.Value {
    const to = intParam(params, "to") orelse return badParams(ctx, "view.scroll", "`to` required");
    const w = try zoomDoc(ctx.ptr);
    w.scroll = to;
    return .null;
}

/// Mutates the executor's side effects, then fails. The executor must roll all of it back.
fn panicProbe(ctx: command.Context, params: std.json.Value) command.CommandError!std.json.Value {
    const wants_error = paramValue(params, "panic") != null;
    if (!wants_error) return .null;
    const ex = execOf(ctx.ptr);
    ex.clipboard.length = 123;
    try ex.message("probe");
    try ex.requestTransport(.stop);
    try ex.setLastSelection(command.Range.new(0, 1), &.{7});
    return error.Internal;
}

/// Fixture commands. Every command here is registered in `fake_specs`.
const fake_specs = [_]command.CommandSpec{
    command.command(.{ .id = "mix.volume", .label = "Volume", .run = mixVolume }),
    command.command(.{ .id = "mix.pan", .label = "Pan", .run = mixPan }),
    command.command(.{ .id = "mix.mute", .label = "Mute", .run = mixMute }),
    command.command(.{ .id = "edit.mode", .label = "Edit Mode", .run = editMode }),
    command.noundo(.{ .id = "edit.select", .label = "Select", .run = editSelect }),
    command.noundo(.{ .id = "edit.select_none", .label = "Select None", .run = editSelectNone }),
    command.noundo(.{ .id = "transport.locate", .label = "Locate", .run = transportLocate }),
    command.noundo(.{ .id = "transport.stop", .label = "Stop", .run = transportStop }),
    command.view(.{ .id = "view.zoom_in", .label = "Zoom In", .run = viewZoomIn }),
    command.view(.{ .id = "view.scroll", .label = "Scroll", .run = viewScroll }),
    command.noundo(.{ .id = "test.panic_probe", .label = "Panic Probe", .run = panicProbe }),
};

const FakeRegistry = command.Registry(&.{&fake_specs});

const fake_config: Config = .{
    .find = FakeRegistry.find,
    .query = &fake_query,
    .ops = &fake_ops,
    .keep_edit_mode = keepEditMode,
    .remember_selection = rememberSelection,
};

fn newExecutor(gpa: std.mem.Allocator, demo: bool) !Executor {
    const d = try FakeDoc.create(gpa, demo);
    errdefer fakeRelease(d);
    return Executor.init(gpa, fake_config, .{ .ptr = d });
}

fn newExecutorWith(gpa: std.mem.Allocator, config: Config, demo: bool) !Executor {
    const d = try FakeDoc.create(gpa, demo);
    errdefer fakeRelease(d);
    return Executor.init(gpa, config, .{ .ptr = d });
}

fn fakeDocOf(e: *Executor) *FakeDoc {
    return fromPtr(e.documentPtr());
}

/// Adds a track to the current document through the writable path (the Rust `session_mut`).
fn addTrack(e: *Executor) !u64 {
    const d = fromPtr(try e.editDocument());
    return @intCast(FakeDoc.addFakeTrack(d, "Track"));
}

fn parseParams(a: std.mem.Allocator, text: []const u8) !std.json.Value {
    return std.json.parseFromSliceLeaky(std.json.Value, a, text, .{});
}

test "journal is bounded to max entries" {
    var e = try newExecutor(testing.allocator, false);
    defer e.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // Calling the append helper directly exercises the ring without the cost of cloning the
    // whole document on 10,000+ `track.new` calls.
    var i: usize = 0;
    while (i < MAX_JOURNAL_ENTRIES + 500) : (i += 1) {
        const text = try std.fmt.allocPrint(a, "{{\"name\":\"t{d}\"}}", .{i});
        try e.journalAppend("track.new", try parseParams(a, text));
    }
    try testing.expectEqual(MAX_JOURNAL_ENTRIES, e.journalLen());
    // The oldest entries were dropped, the newest kept: the first remaining is the 501st pushed.
    try testing.expectEqualStrings("{\"name\":\"t500\"}", e.journalAt(0).params);
    const last_name = try std.fmt.allocPrint(a, "{{\"name\":\"t{d}\"}}", .{MAX_JOURNAL_ENTRIES + 499});
    try testing.expectEqualStrings(last_name, e.journalAt(e.journalLen() - 1).params);
    try testing.expectEqualStrings("track.new", e.journalAt(e.journalLen() - 1).id);
}

test "oversized params are truncated in the journal" {
    var e = try newExecutor(testing.allocator, false);
    defer e.deinit();
    const big = try testing.allocator.alloc(u8, MAX_JOURNAL_ENTRY_BYTES * 4);
    defer testing.allocator.free(big);
    @memset(big, 'x');
    const out = try e.journalParams(.{ .string = big });
    defer testing.allocator.free(out);
    try testing.expectEqualStrings(TRUNCATED_MARKER, out);
}

test "small params are kept whole" {
    var e = try newExecutor(testing.allocator, false);
    defer e.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const p = try parseParams(a, "{\"track\":\"Kick\",\"db\":-6.0}");
    const kept = try e.journalParams(p);
    defer testing.allocator.free(kept);
    const whole = try std.json.Stringify.valueAlloc(a, p, .{});
    try testing.expectEqualStrings(whole, kept);
    try testing.expect(!std.mem.eql(u8, TRUNCATED_MARKER, kept));
}

test "cap boundary is exact" {
    var e = try newExecutor(testing.allocator, false);
    defer e.deinit();
    const buf = try testing.allocator.alloc(u8, MAX_JOURNAL_ENTRY_BYTES);
    defer testing.allocator.free(buf);
    @memset(buf, 'x');
    // A JSON string adds two quote bytes. A string of MAX - 2 bytes serializes to exactly
    // MAX bytes, which is kept. One more byte is over the cap and is truncated.
    const exact = try e.journalParams(.{ .string = buf[0 .. MAX_JOURNAL_ENTRY_BYTES - 2] });
    defer testing.allocator.free(exact);
    try testing.expectEqual(MAX_JOURNAL_ENTRY_BYTES, exact.len);
    try testing.expect(!std.mem.eql(u8, TRUNCATED_MARKER, exact));
    const over = try e.journalParams(.{ .string = buf[0 .. MAX_JOURNAL_ENTRY_BYTES - 1] });
    defer testing.allocator.free(over);
    try testing.expectEqualStrings(TRUNCATED_MARKER, over);
}

test "merged gesture is one undo step" {
    var e = try newExecutor(testing.allocator, false);
    defer e.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const t = try addTrack(&e);
    for ([_][]const u8{ "-1", "-2", "-3", "-4" }) |db| {
        const text = try std.fmt.allocPrint(a, "{{\"track\":{d},\"db\":{s}}}", .{ t, db });
        _ = try e.executeMerged("mix.volume", try parseParams(a, text), "fader");
    }
    e.endMerge();
    try testing.expectEqual(@as(usize, 1), e.undoCount());
    _ = try e.undo();
    try testing.expectEqual(@as(f32, 0), fakeDocOf(&e).tracks[t].volume_db);
}

test "a held merge joins other gestures into its step" {
    var e = try newExecutor(testing.allocator, false);
    defer e.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const t = try addTrack(&e);
    try e.holdMerge("pass");
    for ([_]i32{ -1, -2, -3 }) |db| {
        const vol = try std.fmt.allocPrint(a, "{{\"track\":{d},\"db\":{d}}}", .{ t, db });
        _ = try e.executeMerged("mix.volume", try parseParams(a, vol), "fader");
        const pan = try std.fmt.allocPrint(a, "{{\"track\":{d},\"pan\":{d}}}", .{ t, @as(f64, @floatFromInt(db)) / 4.0 });
        _ = try e.executeMerged("mix.pan", try parseParams(a, pan), "pan");
    }
    try testing.expectEqual(@as(usize, 1), e.undoCount());
    try e.holdMerge(null);
    _ = try e.executeMerged("mix.volume", try parseParams(a, "{\"track\":0,\"db\":-6}"), "fader");
    try testing.expectEqual(@as(usize, 2), e.undoCount());
}

test "only a change to the document ends a gesture" {
    var e = try newExecutor(testing.allocator, false);
    defer e.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    _ = try addTrack(&e);
    _ = try e.executeMerged("mix.volume", try parseParams(a, "{\"track\":0,\"db\":-1}"), "fader");
    _ = try e.execute("transport.stop", try parseParams(a, "{}"));
    _ = try e.executeMerged("mix.volume", try parseParams(a, "{\"track\":0,\"db\":-2}"), "fader");
    try testing.expectEqual(@as(usize, 1), e.undoCount());
    _ = try e.execute("mix.mute", try parseParams(a, "{\"track\":0}"));
    _ = try e.executeMerged("mix.volume", try parseParams(a, "{\"track\":0,\"db\":-3}"), "fader");
    try testing.expectEqual(@as(usize, 3), e.undoCount());
}

test "selecting, locating and zooming leave the session clean" {
    var e = try newExecutor(testing.allocator, true);
    defer e.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const steps = [_]struct { id: []const u8, params: []const u8 }{
        .{ .id = "edit.select", .params = "{\"tracks\":[\"Kick\"],\"start\":0,\"end\":48000}" },
        .{ .id = "edit.select_none", .params = "{}" },
        .{ .id = "transport.locate", .params = "{\"at\":96000}" },
        .{ .id = "view.zoom_in", .params = "{}" },
        .{ .id = "view.scroll", .params = "{\"to\":48000}" },
    };
    for (steps) |s| {
        _ = try e.execute(s.id, try parseParams(a, s.params));
        try testing.expect(!e.isDirty());
    }
    _ = try e.execute("mix.mute", try parseParams(a, "{\"track\":\"Kick\"}"));
    try testing.expect(e.isDirty());
    _ = try e.undo();
    try testing.expect(!e.isDirty());
}

test "dirty state follows save, undo and redo after navigation" {
    var e = try newExecutor(testing.allocator, false);
    defer e.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const track = try addTrack(&e);
    e.markClean();
    _ = try e.execute("mix.volume", try parseParams(a, try std.fmt.allocPrint(a, "{{\"track\":{d},\"db\":-6}}", .{track})));
    try testing.expect(e.isDirty());
    // A repeated check uses the revision cache.
    try testing.expect(e.isDirty());
    e.markClean();
    try testing.expect(!e.isDirty());
    _ = try e.execute("edit.select", try parseParams(a, try std.fmt.allocPrint(a, "{{\"tracks\":[{d}],\"start\":100,\"end\":200}}", .{track})));
    _ = try e.execute("transport.locate", try parseParams(a, "{\"at\":300}"));
    _ = try e.execute("view.zoom_in", try parseParams(a, "{}"));
    try testing.expect(!e.isDirty());
    try testing.expect(try e.undo());
    try testing.expect(e.isDirty()); // undoing away from the saved fader value is dirty
    try testing.expect(try e.redo());
    try testing.expect(!e.isDirty()); // redoing to the saved fader value is clean despite navigation
    _ = try e.execute("mix.volume", try parseParams(a, try std.fmt.allocPrint(a, "{{\"track\":{d},\"db\":-12}}", .{track})));
    try testing.expect(e.isDirty());
    try testing.expect(try e.undo());
    try testing.expect(!e.isDirty());
    try testing.expect(try e.redo());
    try testing.expect(e.isDirty());
}

test "a panicking command restores side effect state" {
    var e = try newExecutor(testing.allocator, false);
    defer e.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // Non-default values, so clearing them instead of restoring them would fail.
    e.clipboard.length = 42;
    try e.message("prior");
    try e.requestTransport(.stop);
    try e.setLastSelection(command.Range.new(20, 30), &.{});

    const r = e.execute("test.panic_probe", try parseParams(a, "{\"panic\":true}"));
    try testing.expectError(error.Internal, r);
    try testing.expectEqual(@as(i64, 42), e.clipboard.length);
    try testing.expectEqual(@as(usize, 1), e.messages.items.len);
    try testing.expectEqualStrings("prior", e.messages.items[0]);
    try testing.expectEqual(@as(usize, 1), e.transport_requests.items.len);
    try testing.expect(std.meta.eql(@as(TransportRequest, .stop), e.transport_requests.items[0]));
    const ls = e.last_selection orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(i64, 20), ls.range.start);
    try testing.expectEqual(@as(i64, 30), ls.range.end);
    try testing.expectEqual(@as(usize, 0), ls.tracks.len);
    const f = e.lastFailure() orelse return error.TestUnexpectedResult;
    try testing.expectEqual(EngineError.Internal, f.err);
    try testing.expectEqualStrings("test.panic_probe", f.id);
}

// ---- tests added with the port (not in lib.rs) ----

test "history keeps at most history_limit steps and drops the oldest" {
    var cfg = fake_config;
    cfg.history_limit = 2;
    var e = try newExecutorWith(testing.allocator, cfg, false);
    defer e.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    _ = try addTrack(&e);
    for ([_][]const u8{ "-1", "-2", "-3" }) |db| {
        const text = try std.fmt.allocPrint(a, "{{\"track\":0,\"db\":{s}}}", .{db});
        _ = try e.execute("mix.volume", try parseParams(a, text));
    }
    try testing.expectEqual(@as(usize, 2), e.undoCount());
    _ = try e.undo();
    _ = try e.undo();
    try testing.expect(!e.canUndo());
    // The two steps kept hold the snapshots from before -2 and -3, so the oldest reachable
    // value is -1, not the original 0.
    try testing.expectEqual(@as(f32, -1), fakeDocOf(&e).tracks[0].volume_db);
}

test "undo keeps the current edit mode, as in Rust" {
    var e = try newExecutor(testing.allocator, false);
    defer e.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    _ = try addTrack(&e);
    _ = try e.execute("mix.volume", try parseParams(a, "{\"track\":0,\"db\":-6}"));
    _ = try e.execute("edit.mode", try parseParams(a, "{\"mode\":1}"));
    // Undoing the mode change restores the snapshot taken before it (volume -6, mode 0), but
    // the mode stays at the current value, 1.
    _ = try e.undo();
    try testing.expectEqual(@as(f32, -6), fakeDocOf(&e).tracks[0].volume_db);
    try testing.expectEqual(@as(u8, 1), fakeDocOf(&e).edit_mode);
}
