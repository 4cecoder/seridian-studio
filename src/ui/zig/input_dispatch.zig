//! Fixed-capacity input dispatcher. Raven allows one window event hook per window, so several UI components share
//! that hook through a dispatcher. Handlers run in registration order. A handler returns non-zero to consume the
//! event, which stops later handlers from seeing it.
//!
//! No Raven dependency: the event is an opaque pointer whose type is decided by the caller.
//! Translated from src/ui/input_dispatch.h; tests ported from tests/ui/input_dispatch_test.c.

pub const INPUT_MAX_HANDLERS = 8;

/// Returns non-zero when the handler consumed the event.
pub const InputHandler = ?*const fn (context: ?*anyopaque, event: ?*const anyopaque) callconv(.c) c_int;

/// Holds borrowed handler contexts: the dispatcher never frees them.
pub const InputDispatcher = extern struct {
    count: c_int,
    handlers: [INPUT_MAX_HANDLERS]InputHandler,
    contexts: [INPUT_MAX_HANDLERS]?*anyopaque,
};

/// Clears all registrations.
pub fn input_dispatcher_init(dispatcher: *InputDispatcher) void {
    dispatcher.count = 0;
    for (0..INPUT_MAX_HANDLERS) |i| {
        dispatcher.handlers[i] = null;
        dispatcher.contexts[i] = null;
    }
}

/// Appends a handler. Returns 0 on success, or -1 when the handler is null or the table is full.
pub fn input_dispatcher_add(dispatcher: *InputDispatcher, handler: InputHandler, context: ?*anyopaque) c_int {
    if (handler == null or dispatcher.count >= INPUT_MAX_HANDLERS) return -1;
    const slot: usize = @intCast(dispatcher.count);
    dispatcher.handlers[slot] = handler;
    dispatcher.contexts[slot] = context;
    dispatcher.count += 1;
    return 0;
}

/// Calls handlers in order. Returns 1 when one consumed the event, otherwise 0.
pub fn input_dispatch(dispatcher: *InputDispatcher, event: ?*const anyopaque) c_int {
    var i: usize = 0;
    while (i < @as(usize, @intCast(dispatcher.count))) : (i += 1) {
        // A registered slot is never null: input_dispatcher_add refuses null handlers.
        const handler = dispatcher.handlers[i] orelse continue;
        if (handler(dispatcher.contexts[i], event) != 0) return 1;
    }
    return 0;
}
