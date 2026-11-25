//! Wraps a tab's content in a scroll box, so nothing in it is unreachable when the window is small (docs/QA.md U11).
//! Written against an `api` value, so the structure is tested with a recording mock and no display; the window
//! passes a thin adapter over Raven.

const std = @import("std");

/// Puts `content` inside a new scroll box that fills its parent and returns the scroll box.
/// `api` provides: `createScrollBox() Id`, `addChild(parent: Id, child: Id) void`, `setFill(widget: Id, weight: f32) void`.
pub fn wrap(api: anytype, content: anytype) @TypeOf(content) {
    const scroll = api.createScrollBox();
    api.addChild(scroll, content);
    api.setFill(scroll, 1.0);
    return scroll;
}

const MockApi = struct {
    const Id = u32;
    const Call = union(enum) {
        create_scroll_box: Id,
        add_child: struct { parent: Id, child: Id },
        set_fill: struct { widget: Id, weight: f32 },
    };
    calls: [8]Call = undefined,
    count: usize = 0,
    next_id: Id = 100,

    fn record(self: *MockApi, call: Call) void {
        self.calls[self.count] = call;
        self.count += 1;
    }
    pub fn createScrollBox(self: *MockApi) Id {
        const id = self.next_id;
        self.next_id += 1;
        self.record(.{ .create_scroll_box = id });
        return id;
    }
    pub fn addChild(self: *MockApi, parent: Id, child: Id) void {
        self.record(.{ .add_child = .{ .parent = parent, .child = child } });
    }
    pub fn setFill(self: *MockApi, widget: Id, weight: f32) void {
        self.record(.{ .set_fill = .{ .widget = widget, .weight = weight } });
    }
};

test "scroll wrap: content goes inside a scroll box that is returned and fills its parent" {
    var api: MockApi = .{};
    const content: u32 = 7;
    const result = wrap(&api, content);

    try std.testing.expect(result != content);
    try std.testing.expectEqual(@as(u32, 100), result);
    var created = false;
    var parented = false;
    var filled = false;
    for (api.calls[0..api.count]) |call| switch (call) {
        .create_scroll_box => |id| created = id == result,
        .add_child => |c| parented = c.parent == result and c.child == content,
        .set_fill => |f| filled = f.widget == result and f.weight == 1.0,
    };
    try std.testing.expect(created);
    try std.testing.expect(parented);
    try std.testing.expect(filled);
}
