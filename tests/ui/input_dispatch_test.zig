//! Input dispatcher rules (ported from tests/ui/input_dispatch_test.c, every assertion kept).

const std = @import("std");
const input = @import("ui_impl").input_dispatch;
const expect = std.testing.expect;

/// A handler that records every call and consumes events whose kind matches `consume_kind`.
const Recorder = struct {
    calls: c_int = 0,
    consume_kind: c_int,
    last_kind: c_int = 0,
};

fn recordHandler(context: ?*anyopaque, event: ?*const anyopaque) callconv(.c) c_int {
    const kind = @as(*const c_int, @ptrCast(@alignCast(event))).*;
    const recorder: *Recorder = @ptrCast(@alignCast(context));
    recorder.calls += 1;
    recorder.last_kind = kind;
    return if (kind == recorder.consume_kind) 1 else 0;
}

/// Dispatches an integer event kind through the pointer-based API.
fn dispatchKind(dispatcher: *input.InputDispatcher, kind: c_int) c_int {
    var k = kind;
    return input.input_dispatch(dispatcher, &k);
}

test "empty dispatcher consumes nothing" {
    var dispatcher: input.InputDispatcher = undefined;
    input.input_dispatcher_init(&dispatcher);
    try expect(dispatchKind(&dispatcher, 3) == 0);
}

test "handler that consumes stops later handlers" {
    var dispatcher: input.InputDispatcher = undefined;
    var first: Recorder = .{ .consume_kind = 7 };
    var second: Recorder = .{ .consume_kind = -1 };
    input.input_dispatcher_init(&dispatcher);
    try expect(input.input_dispatcher_add(&dispatcher, recordHandler, &first) == 0);
    try expect(input.input_dispatcher_add(&dispatcher, recordHandler, &second) == 0);

    try expect(dispatchKind(&dispatcher, 7) == 1);
    try expect(first.calls == 1);
    try expect(second.calls == 0);
}

test "unconsumed event reaches every handler" {
    var dispatcher: input.InputDispatcher = undefined;
    var first: Recorder = .{ .consume_kind = 7 };
    var second: Recorder = .{ .consume_kind = 8 };
    input.input_dispatcher_init(&dispatcher);
    try expect(input.input_dispatcher_add(&dispatcher, recordHandler, &first) == 0);
    try expect(input.input_dispatcher_add(&dispatcher, recordHandler, &second) == 0);

    try expect(dispatchKind(&dispatcher, 3) == 0);
    try expect(first.calls == 1);
    try expect(second.calls == 1);
    try expect(second.last_kind == 3);
}

test "registration order is call order" {
    var dispatcher: input.InputDispatcher = undefined;
    var first: Recorder = .{ .consume_kind = -1 };
    var second: Recorder = .{ .consume_kind = -1 };
    input.input_dispatcher_init(&dispatcher);
    try expect(input.input_dispatcher_add(&dispatcher, recordHandler, &first) == 0);
    try expect(input.input_dispatcher_add(&dispatcher, recordHandler, &second) == 0);
    try expect(dispatchKind(&dispatcher, 1) == 0);
    try expect(first.calls == 1 and second.calls == 1);
}

test "registration beyond capacity fails" {
    var dispatcher: input.InputDispatcher = undefined;
    var recorder: Recorder = .{ .consume_kind = -1 };
    input.input_dispatcher_init(&dispatcher);
    for (0..input.INPUT_MAX_HANDLERS) |_| {
        try expect(input.input_dispatcher_add(&dispatcher, recordHandler, &recorder) == 0);
    }
    try expect(input.input_dispatcher_add(&dispatcher, recordHandler, &recorder) == -1);
}

test "null handler is rejected" {
    var dispatcher: input.InputDispatcher = undefined;
    input.input_dispatcher_init(&dispatcher);
    try expect(input.input_dispatcher_add(&dispatcher, null, null) == -1);
    try expect(dispatchKind(&dispatcher, 1) == 0);
}
