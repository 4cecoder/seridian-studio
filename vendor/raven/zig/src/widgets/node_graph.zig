// Translated to Zig from vendor/raven/src/widgets/node_graph.c (Raven, Apache-2.0). Modified by Seridian: C11 → Zig translation.
//
// Raven - widgets/node_graph.c
// NodeGraph: nodes with pins, on a canvas that pans and zooms, linked by
// wires.
//
// Three spaces:
//
//   canvas   where the nodes are (their x, y): what the application sees
//   widget   logical units from the corner of the widget, as everywhere
//   layer    the canvas, shifted so that scaling it by the zoom around the
//            corner of the widget puts it where it shows
//
//   widget = pan + zoom * canvas          layer = canvas + pan / zoom
//
// Everything that zooms (wires, nodes, the widgets inside the nodes) is
// painted in the layer, at the size it has at the zoom asked for (so that
// text is drawn at its real size, not stretched), and the little that is
// left while the zoom glides there is a scale applied to what was drawn
// (rvn_drawlist_transform). The widgets inside the nodes are children of the
// graph, laid out in the layer: `child_scale` tells the hit tests and the
// events that they show scaled.
//
// A wire is one cubic curve (R_PRIM_CURVE). It hangs a little, and its
// middle is on a spring: when one of its ends moves, the middle lags behind
// and swings back, as a cable would.

const std = @import("std");
const raven = @import("raven");
const base = @import("../core/base_h.zig");
const ctx_h = @import("../core/context_h.zig");
const font_h = @import("../render/font_h.zig");
const draw_h = @import("../render/draw_h.zig");
const thread_h = @import("../core/thread_h.zig");
const widget_h = @import("../widget/widget_h.zig");
const xml_h = @import("../xml/xml_h.zig");
const common_h = @import("common_h.zig");
const libc = @import("../sys/libc.zig");

const RVN_NG_HEADER: f32 = 30.0;
const RVN_NG_ROW: f32 = 24.0;
const RVN_NG_PAD: f32 = 10.0;
const RVN_NG_RADIUS: f32 = 11.0;
const RVN_NG_PIN: f32 = 5.0;
const RVN_NG_MIN_WIDTH: f32 = 148.0;
const RVN_NG_GRID: f32 = 24.0;
const RVN_NG_ZOOM_MIN: f32 = 0.2;
const RVN_NG_ZOOM_MAX: f32 = 2.0;
/// Below this zoom the widgets inside the nodes are too small to be used: clicks go to the node.
const RVN_NG_ZOOM_USABLE: f32 = 0.45;

/// Modifier masks as unsigned values (the event carries them as u32).
const RVN_MOD_SHIFT: u32 = @intCast(raven.R_MOD_SHIFT);
const RVN_MOD_CTRL: u32 = @intCast(raven.R_MOD_CTRL);
const RVN_MOD_ALT: u32 = @intCast(raven.R_MOD_ALT);

/// Moved-to-zero marker of the C `(uint32_t)-1` loop restarts: `i +%= 1` then wraps to 0.
const RVN_NG_RESTART: u32 = std.math.maxInt(u32);

const rvn_ng_drag_t = c_uint;
/// Moving the selected nodes.
const RVN_NG_DRAG_NONE: rvn_ng_drag_t = 0;
const RVN_NG_DRAG_MOVE: rvn_ng_drag_t = 1;
/// Pulling a wire out of a pin.
const RVN_NG_DRAG_LINK: rvn_ng_drag_t = 2;
/// A selection rectangle.
const RVN_NG_DRAG_BOX: rvn_ng_drag_t = 3;
const RVN_NG_DRAG_PAN: rvn_ng_drag_t = 4;

const rvn_ng_flow_t = c_uint;
/// While the pointer is over the graph.
const RVN_NG_FLOW_AUTO: rvn_ng_flow_t = 0;
const RVN_NG_FLOW_ALWAYS: rvn_ng_flow_t = 1;
const RVN_NG_FLOW_NEVER: rvn_ng_flow_t = 2;

const rvn_ng_type_t = extern struct {
    name: [*c]u8,
    color: base.rvn_color_t,
    has_color: c_int,
};

const rvn_ng_pin_t = extern struct {
    id: c_int,
    node: c_int,
    output: c_int,
    name: [*c]u8,
    label: [*c]u8,
    /// Index of its type, or -1: links to anything.
    type: c_int,
    /// set by the geometry: from the corner of its node
    x: f32,
    y: f32,
    label_width: f32,
    /// Set while painting: a link ends here.
    linked: c_int,
    /// How much it stands out: under the pointer, or where the wire being pulled could go.
    hot: raven.RSpring,
    /// A ring that leaves the pin when a link is made.
    pulse: raven.RSpring,
    /// Input that takes several links (Rnode_graph_set_pin_multiple).
    multiple: c_int,
};

const rvn_ng_node_t = extern struct {
    id: c_int,
    name: [*c]u8,
    title: [*c]u8,
    x: f32,
    y: f32,
    /// set by the geometry
    w: f32,
    h: f32,
    content_rect: base.rvn_rect_t,
    color: base.rvn_color_t,
    has_color: c_int,
    content: [*c]widget_h.rvn_widget_t,
    user: ?*anyopaque,
    selected: c_int,
    /// where it was when the gesture started
    from_x: f32,
    from_y: f32,
    from_selected: c_int,
    lift: raven.RSpring,
    appear: raven.RSpring,
    glow: raven.RSpring,
    /// Running (Rnode_graph_set_node_active): a ring breathes around it.
    active: c_int,
    active_color: base.rvn_color_t,
    has_active_color: c_int,
    active_shown: raven.RSpring,
    /// Small text in a pill on the top right corner (Rnode_graph_set_node_badge), or NULL.
    badge: [*c]u8,
    badge_shown: raven.RSpring,
    /// R_TRUE: the Delete key leaves it (Rnode_graph_set_node_deletable).
    undeletable: c_int,
};

const rvn_ng_link_t = extern struct {
    id: c_int,
    /// Output pin, input pin.
    from: c_int,
    to: c_int,
    selected: c_int,
    hover: raven.RSpring,
    /// 0 -> 1 while it is drawn in, from the output to the input.
    grow: raven.RSpring,
    /// The swing of its middle.
    sway_x: raven.RSpring,
    sway_y: raven.RSpring,
    last_x: f32,
    last_y: f32,
    has_last: c_int,
};

/// A wire that is going away: it draws back to its first point.
const rvn_ng_ghost_t = extern struct {
    points: [8]f32,
    from: base.rvn_color_t,
    to: base.rvn_color_t,
    left: raven.RSpring,
};

const rvn_node_graph_t = extern struct {
    base: widget_h.rvn_widget_t,

    nodes: [*c]rvn_ng_node_t,
    node_count: u32,
    node_cap: u32,
    pins: [*c]rvn_ng_pin_t,
    pin_count: u32,
    pin_cap: u32,
    links: [*c]rvn_ng_link_t,
    link_count: u32,
    link_cap: u32,
    types: [*c]rvn_ng_type_t,
    type_count: u32,
    type_cap: u32,
    ghosts: [*c]rvn_ng_ghost_t,
    ghost_count: u32,
    ghost_cap: u32,
    next_id: c_int,

    // ---- the view asked for ----
    center_x: f32,
    center_y: f32,
    zoom: f32,
    /// Until the view is moved, the corner of the canvas is at the corner of the widget, whatever its size.
    pinned: c_int,
    shown_x: raven.RSpring,
    shown_y: raven.RSpring,
    shown_zoom: raven.RSpring,
    // ---- the view drawn (what the mouse works with) ----
    pan_x: f32,
    pan_y: f32,
    draw_zoom: f32,
    painted: c_int,
    /// Rnode_graph_frame_all was called before the widget had a size.
    frame_pending: c_int,

    grid_hidden: c_int,
    flow_mode: rvn_ng_flow_t,
    read_only: c_int,
    flow: raven.RSpring,
    flow_time: f32,
    geometry_dirty: c_int,
    bold: raven.Rid,

    // ---- gesture ----
    drag: rvn_ng_drag_t,
    drag_moved: c_int,
    drag_node: c_int,
    /// Where the button went down: in the widget, and on the canvas.
    press_x: f32,
    press_y: f32,
    press_cx: f32,
    press_cy: f32,
    pan_from_x: f32,
    pan_from_y: f32,
    pan_speed_x: f32,
    pan_speed_y: f32,
    pan_clock: f64,
    /// Selection rectangle, in the widget.
    box: base.rvn_rect_t,
    box_add: c_int,
    /// The pin the wire being pulled is attached to.
    wire_pin: c_int,
    /// The link that was picked up by its input end, hidden meanwhile; 0 = a new wire.
    wire_detached: c_int,
    /// The pin the free end would link to if released now, or 0.
    wire_target: c_int,
    /// Free end, on the canvas.
    wire_x: f32,
    wire_y: f32,
    wire_snap: raven.RSpring,
    wire_sway_x: raven.RSpring,
    wire_sway_y: raven.RSpring,
    wire_last_x: f32,
    wire_last_y: f32,
    wire_has_last: c_int,
    space_down: c_int,

    hot_node: c_int,
    hot_pin: c_int,
    hot_link: c_int,
    mouse_in: c_int,

    connect_callback: raven.RNodeGraphConnectCallback,
    connect_user: ?*anyopaque,
    linked_callback: raven.RNodeGraphItemCallback,
    linked_user: ?*anyopaque,
    unlinked_callback: raven.RNodeGraphItemCallback,
    unlinked_user: ?*anyopaque,
    moved_callback: raven.RNodeGraphItemCallback,
    moved_user: ?*anyopaque,
    selection_callback: raven.RNodeGraphItemCallback,
    selection_user: ?*anyopaque,
    removed_callback: raven.RNodeGraphItemCallback,
    removed_user: ?*anyopaque,
    activated_callback: raven.RNodeGraphItemCallback,
    activated_user: ?*anyopaque,
    context_callback: raven.RNodeGraphContextCallback,
    context_user: ?*anyopaque,
    /// Clock of the breathing ring of the active nodes.
    active_time: f32,
};

const g_ng_palette = [_]u32{
    0x64D2FF, 0x30D158, 0xFFD60A, 0xFF9F0A, 0xFF6482, 0xBF5AF2, 0x7D7AFF, 0x66D4CF, 0xFFB340, 0xDA8FFF,
};
/// The zooms the wheel stops at.
const g_ng_stops = [_]f32{ 0.2, 0.25, 0.35, 0.5, 0.65, 0.8, 1.0, 1.25, 1.5, 2.0 };

// ---------------------------------------------------------------------------
//  Model
// ---------------------------------------------------------------------------

fn rvn_ng_changed(graph: [*c]rvn_node_graph_t) void {
    graph.*.geometry_dirty = raven.R_TRUE;
    widget_h.rvn_widget_invalidate_layout(&graph.*.base);
    widget_h.rvn_widget_invalidate_paint(&graph.*.base);
}

fn rvn_ng_node(graph: [*c]const rvn_node_graph_t, id: c_int) [*c]rvn_ng_node_t {
    var i: u32 = 0;
    if (id <= 0) return null;
    while (i < graph.*.node_count) : (i += 1) {
        if (graph.*.nodes[i].id == id) return &graph.*.nodes[i];
    }
    return null;
}

fn rvn_ng_pin(graph: [*c]const rvn_node_graph_t, id: c_int) [*c]rvn_ng_pin_t {
    var i: u32 = 0;
    if (id <= 0) return null;
    while (i < graph.*.pin_count) : (i += 1) {
        if (graph.*.pins[i].id == id) return &graph.*.pins[i];
    }
    return null;
}

fn rvn_ng_link(graph: [*c]const rvn_node_graph_t, id: c_int) [*c]rvn_ng_link_t {
    var i: u32 = 0;
    if (id <= 0) return null;
    while (i < graph.*.link_count) : (i += 1) {
        if (graph.*.links[i].id == id) return &graph.*.links[i];
    }
    return null;
}

fn rvn_ng_type(graph: [*c]rvn_node_graph_t, name: [*c]const u8) c_int {
    var i: u32 = 0;
    if (name == null or name[0] == 0) return -1;
    while (i < graph.*.type_count) : (i += 1) {
        if (libc.strcmp(graph.*.types[i].name, name) == 0) return @intCast(i);
    }
    base.RVN_ARRAY_RESERVE(&graph.*.types, &graph.*.type_cap, graph.*.type_count + 1);
    const index = graph.*.type_count;
    graph.*.type_count += 1;
    const ty: [*c]rvn_ng_type_t = &graph.*.types[index];
    ty.* = std.mem.zeroes(rvn_ng_type_t);
    ty.*.name = base.rvn_strdup(name);
    return @as(c_int, @intCast(graph.*.type_count)) - 1;
}

fn rvn_ng_pin_color(graph: [*c]const rvn_node_graph_t, pin: [*c]const rvn_ng_pin_t) base.rvn_color_t {
    if (pin.*.type < 0 or @as(c_uint, @bitCast(pin.*.type)) >= graph.*.type_count) {
        // a pin that takes anything: neither a color nor the text
        return base.rvn_color_mix(widget_h.rvn_widget_color(&graph.*.base, raven.R_COLOR_TEXT), base.rvn_hex(0x8A93A6, 255), 0.55) | 0xFF000000;
    }
    const ty: [*c]const rvn_ng_type_t = &graph.*.types[@intCast(pin.*.type)];
    if (ty.*.has_color != 0) return ty.*.color;
    return base.rvn_hex(g_ng_palette[base.rvn_hash_str(ty.*.name) % g_ng_palette.len], 255);
}

/// May a wire go between these two pins?
fn rvn_ng_can_link(a: [*c]const rvn_ng_pin_t, b: [*c]const rvn_ng_pin_t) c_int {
    if (a == null or b == null or a == b) return raven.R_FALSE;
    if (a.*.output == b.*.output or a.*.node == b.*.node) return raven.R_FALSE;
    return @intFromBool(a.*.type < 0 or b.*.type < 0 or a.*.type == b.*.type);
}

fn rvn_ng_input_link(graph: [*c]const rvn_node_graph_t, input_pin: c_int) [*c]rvn_ng_link_t {
    var i: u32 = 0;
    while (i < graph.*.link_count) : (i += 1) {
        if (graph.*.links[i].to == input_pin) return &graph.*.links[i];
    }
    return null;
}

fn rvn_ng_remove_link_at(graph: [*c]rvn_node_graph_t, index: u32) void {
    const id = graph.*.links[index].id;
    _ = libc.memmove(&graph.*.links[index], &graph.*.links[index + 1], @as(usize, graph.*.link_count - index - 1) * @sizeOf(rvn_ng_link_t));
    graph.*.link_count -= 1;
    if (graph.*.hot_link == id) graph.*.hot_link = 0;
    if (graph.*.wire_detached == id) graph.*.wire_detached = 0;
    widget_h.rvn_widget_invalidate_paint(&graph.*.base);
}

fn rvn_ng_remove_link(graph: [*c]rvn_node_graph_t, id: c_int) void {
    var i: u32 = 0;
    while (i < graph.*.link_count) : (i += 1) {
        if (graph.*.links[i].id == id) {
            rvn_ng_remove_link_at(graph, i);
            return;
        }
    }
}

/// The link between two pins (made if needed; the input loses the one it had). `draw_in`: it is seen growing.
fn rvn_ng_add_link(graph: [*c]rvn_node_graph_t, output_pin: c_int, input_pin: c_int, draw_in: c_int) c_int {
    const input = rvn_ng_pin(graph, input_pin);
    const multiple = input != null and input.*.multiple != 0;
    var i: u32 = 0;
    while (i < graph.*.link_count) : (i += 1) {
        if (graph.*.links[i].to != input_pin) continue;
        if (graph.*.links[i].from == output_pin) return graph.*.links[i].id;
        if (multiple) continue;
        rvn_ng_remove_link_at(graph, i);
        break;
    }
    base.RVN_ARRAY_RESERVE(&graph.*.links, &graph.*.link_cap, graph.*.link_count + 1);
    const index = graph.*.link_count;
    graph.*.link_count += 1;
    const link: [*c]rvn_ng_link_t = &graph.*.links[index];
    link.* = std.mem.zeroes(rvn_ng_link_t);
    link.*.id = graph.*.next_id;
    graph.*.next_id += 1;
    link.*.from = output_pin;
    link.*.to = input_pin;
    if (draw_in == 0 or graph.*.painted == 0) draw_h.rvn_spring_set(&link.*.grow, 1.0);
    widget_h.rvn_widget_invalidate_paint(&graph.*.base);
    return link.*.id;
}

fn rvn_ng_free_pin(pin: [*c]rvn_ng_pin_t) void {
    base.rvn_free(pin.*.name);
    base.rvn_free(pin.*.label);
}

fn rvn_ng_remove_pin_at(graph: [*c]rvn_node_graph_t, index: u32) void {
    const id = graph.*.pins[index].id;
    var i: u32 = graph.*.link_count;
    while (i > 0) : (i -= 1) {
        if (graph.*.links[i - 1].from == id or graph.*.links[i - 1].to == id) rvn_ng_remove_link_at(graph, i - 1);
    }
    rvn_ng_free_pin(&graph.*.pins[index]);
    _ = libc.memmove(&graph.*.pins[index], &graph.*.pins[index + 1], @as(usize, graph.*.pin_count - index - 1) * @sizeOf(rvn_ng_pin_t));
    graph.*.pin_count -= 1;
    if (graph.*.hot_pin == id) graph.*.hot_pin = 0;
    if (graph.*.wire_target == id) graph.*.wire_target = 0;
}

fn rvn_ng_remove_node(graph: [*c]rvn_node_graph_t, id: c_int) void {
    var index: u32 = 0;
    var i: u32 = undefined;
    while (index < graph.*.node_count and graph.*.nodes[index].id != id) : (index += 1) {}
    if (index >= graph.*.node_count) return;
    // a gesture that was about this node ends here
    if (graph.*.drag == RVN_NG_DRAG_MOVE or graph.*.drag == RVN_NG_DRAG_LINK) {
        const pin = rvn_ng_pin(graph, graph.*.wire_pin);
        if (graph.*.drag == RVN_NG_DRAG_MOVE or (pin != null and pin.*.node == id)) {
            graph.*.drag = RVN_NG_DRAG_NONE;
            widget_h.rvn_widget_release_mouse(&graph.*.base);
        }
    }
    i = graph.*.pin_count;
    while (i > 0) : (i -= 1) {
        if (graph.*.pins[i - 1].node == id) rvn_ng_remove_pin_at(graph, i - 1);
    }
    const content = graph.*.nodes[index].content;
    base.rvn_free(graph.*.nodes[index].name);
    base.rvn_free(graph.*.nodes[index].title);
    base.rvn_free(graph.*.nodes[index].badge);
    _ = libc.memmove(&graph.*.nodes[index], &graph.*.nodes[index + 1], @as(usize, graph.*.node_count - index - 1) * @sizeOf(rvn_ng_node_t));
    graph.*.node_count -= 1;
    if (graph.*.hot_node == id) graph.*.hot_node = 0;
    if (graph.*.drag_node == id) graph.*.drag_node = 0;
    // (last: destroying a child calls back into the class)
    if (content != null) widget_h.rvn_widget_destroy(content);
    rvn_ng_changed(graph);
}

fn rvn_ng_clear(graph: [*c]rvn_node_graph_t) void {
    while (graph.*.node_count > 0) rvn_ng_remove_node(graph, graph.*.nodes[graph.*.node_count - 1].id);
    graph.*.ghost_count = 0;
}

/// The node goes over the others.
fn rvn_ng_raise(graph: [*c]rvn_node_graph_t, id: c_int) void {
    var index: u32 = 0;
    while (index < graph.*.node_count and graph.*.nodes[index].id != id) : (index += 1) {}
    if (index + 1 >= graph.*.node_count) return;
    const moved = graph.*.nodes[index];
    _ = libc.memmove(&graph.*.nodes[index], &graph.*.nodes[index + 1], @as(usize, graph.*.node_count - index - 1) * @sizeOf(rvn_ng_node_t));
    graph.*.nodes[graph.*.node_count - 1] = moved;
}

// ---------------------------------------------------------------------------
//  Geometry of the nodes
// ---------------------------------------------------------------------------

fn rvn_ng_geometry(graph: [*c]rvn_node_graph_t) void {
    const widget: [*c]widget_h.rvn_widget_t = &graph.*.base;
    var i: u32 = 0;

    if (graph.*.geometry_dirty == 0) return;
    graph.*.geometry_dirty = raven.R_FALSE;
    const size = common_h.rvn_widget_font_size(widget, 0.0);
    const small = @floor(size * 0.9);
    graph.*.bold = font_h.rvn_font_variant(raven.R_INVALID_ID, font_h.RVN_FONT_BOLD);

    while (i < graph.*.node_count) : (i += 1) {
        const node: [*c]rvn_ng_node_t = &graph.*.nodes[i];
        var inputs: c_int = 0;
        var outputs: c_int = 0;
        var widest_in: f32 = 0.0;
        var widest_out: f32 = 0.0;
        var width: f32 = base.rvn_maxf(RVN_NG_MIN_WIDTH, common_h.rvn_widget_text_width(widget, graph.*.bold, size, node.*.title) + 30.0);
        var content = base.rvn_vec2(0.0, 0.0);

        var k: u32 = 0;
        while (k < graph.*.pin_count) : (k += 1) {
            const pin: [*c]rvn_ng_pin_t = &graph.*.pins[k];
            var row: c_int = undefined;
            if (pin.*.node != node.*.id) continue;
            pin.*.label_width = common_h.rvn_widget_text_width(widget, raven.R_INVALID_ID, small, pin.*.label);
            if (pin.*.output != 0) {
                row = outputs;
                outputs += 1;
            } else {
                row = inputs;
                inputs += 1;
            }
            pin.*.y = RVN_NG_HEADER + 7.0 + RVN_NG_ROW * (@as(f32, @floatFromInt(row)) + 0.5);
            if (pin.*.output != 0) {
                widest_out = base.rvn_maxf(widest_out, pin.*.label_width);
            } else {
                widest_in = base.rvn_maxf(widest_in, pin.*.label_width);
            }
        }
        const rows: c_int = if (inputs > outputs) inputs else outputs;
        width = base.rvn_maxf(width, widest_in + widest_out + 28.0 + (if (widest_in > 0.0 and widest_out > 0.0) @as(f32, 20.0) else @as(f32, 0.0)));
        if (node.*.content != null and node.*.content.*.visibility != raven.R_COLLAPSED) {
            content = widget_h.rvn_widget_measure(node.*.content);
            width = base.rvn_maxf(width, content.x + RVN_NG_PAD * 2.0);
        }
        node.*.w = @ceil(width);
        k = 0;
        while (k < graph.*.pin_count) : (k += 1) {
            if (graph.*.pins[k].node == node.*.id) graph.*.pins[k].x = if (graph.*.pins[k].output != 0) node.*.w else 0.0;
        }
        const top: f32 = RVN_NG_HEADER + (if (rows > 0) 7.0 + RVN_NG_ROW * @as(f32, @floatFromInt(rows)) else @as(f32, 0.0));
        if (content.y > 0.0) {
            node.*.content_rect = base.rvn_rect(RVN_NG_PAD, top + 6.0, node.*.w - RVN_NG_PAD * 2.0, content.y);
            node.*.h = @ceil(top + 6.0 + content.y + RVN_NG_PAD);
        } else {
            node.*.content_rect = base.rvn_rect(RVN_NG_PAD, top, node.*.w - RVN_NG_PAD * 2.0, 0.0);
            node.*.h = @ceil(top + (if (rows > 0) @as(f32, 5.0) else @as(f32, 8.0)));
        }
    }
}

fn rvn_ng_pin_at_canvas(graph: [*c]const rvn_node_graph_t, pin: [*c]const rvn_ng_pin_t) base.rvn_vec2_t {
    const node = rvn_ng_node(graph, pin.*.node);
    return if (node != null) base.rvn_vec2(node.*.x + pin.*.x, node.*.y + pin.*.y) else base.rvn_vec2(0.0, 0.0);
}

// ---------------------------------------------------------------------------
//  View
// ---------------------------------------------------------------------------

/// The view asked for: what the middle of the widget shows.
fn rvn_ng_target(graph: [*c]const rvn_node_graph_t, center_x: [*c]f32, center_y: [*c]f32) void {
    if (graph.*.pinned != 0) {
        center_x.* = graph.*.base.rect.w * 0.5 / graph.*.zoom;
        center_y.* = graph.*.base.rect.h * 0.5 / graph.*.zoom;
    } else {
        center_x.* = graph.*.center_x;
        center_y.* = graph.*.center_y;
    }
}

/// The widgets inside the nodes follow the view: they are laid out in the layer.
fn rvn_ng_place_contents(graph: [*c]rvn_node_graph_t) void {
    const shift_x = graph.*.pan_x / graph.*.draw_zoom;
    const shift_y = graph.*.pan_y / graph.*.draw_zoom;
    var i: u32 = 0;
    while (i < graph.*.node_count) : (i += 1) {
        const node: [*c]rvn_ng_node_t = &graph.*.nodes[i];
        if (node.*.content == null) continue;
        node.*.content.*.rect.x = node.*.x + node.*.content_rect.x + shift_x;
        node.*.content.*.rect.y = node.*.y + node.*.content_rect.y + shift_y;
    }
}

/// Works out the view that is drawn. With a painter the springs move by the
/// time of the frame; without one they are read where they are.
fn rvn_ng_sync(graph: [*c]rvn_node_graph_t, painter: [*c]draw_h.RPainter) void {
    const widget: [*c]widget_h.rvn_widget_t = &graph.*.base;
    const zoom_raw: f32 = if (painter != null)
        draw_h.rvn_paint_spring(painter, &graph.*.shown_zoom, graph.*.zoom, raven.R_MOTION_SMOOTH)
    else if (graph.*.shown_zoom.started != 0) graph.*.shown_zoom.value else graph.*.zoom;
    const zoom = base.rvn_clampf(zoom_raw, RVN_NG_ZOOM_MIN * 0.5, RVN_NG_ZOOM_MAX * 1.5);
    if (graph.*.pinned != 0) {
        graph.*.pan_x = 0.0;
        graph.*.pan_y = 0.0;
    } else {
        const x: f32 = if (painter != null)
            draw_h.rvn_paint_spring(painter, &graph.*.shown_x, graph.*.center_x, raven.R_MOTION_SMOOTH)
        else if (graph.*.shown_x.started != 0) graph.*.shown_x.value else graph.*.center_x;
        const y: f32 = if (painter != null)
            draw_h.rvn_paint_spring(painter, &graph.*.shown_y, graph.*.center_y, raven.R_MOTION_SMOOTH)
        else if (graph.*.shown_y.started != 0) graph.*.shown_y.value else graph.*.center_y;
        graph.*.pan_x = widget.*.rect.w * 0.5 - zoom * x;
        graph.*.pan_y = widget.*.rect.h * 0.5 - zoom * y;
    }
    graph.*.draw_zoom = zoom;
    widget.*.child_scale = zoom;
    rvn_ng_place_contents(graph);
}

/// From now on the view is where it was put, not hung from the corner.
fn rvn_ng_unpin(graph: [*c]rvn_node_graph_t) void {
    var x: f32 = undefined;
    var y: f32 = undefined;
    if (graph.*.pinned == 0) return;
    rvn_ng_target(graph, &x, &y);
    graph.*.center_x = x;
    graph.*.center_y = y;
    graph.*.pinned = raven.R_FALSE;
    draw_h.rvn_spring_set(&graph.*.shown_x, x);
    draw_h.rvn_spring_set(&graph.*.shown_y, y);
}

fn rvn_ng_set_view(graph: [*c]rvn_node_graph_t, x: f32, y: f32, zoom_in: f32, animate: c_int) void {
    rvn_ng_unpin(graph);
    graph.*.center_x = x;
    graph.*.center_y = y;
    graph.*.zoom = base.rvn_clampf(zoom_in, RVN_NG_ZOOM_MIN, RVN_NG_ZOOM_MAX);
    if (animate == 0 or graph.*.painted == 0) {
        draw_h.rvn_spring_set(&graph.*.shown_x, graph.*.center_x);
        draw_h.rvn_spring_set(&graph.*.shown_y, graph.*.center_y);
        draw_h.rvn_spring_set(&graph.*.shown_zoom, graph.*.zoom);
        rvn_ng_sync(graph, null);
    }
    widget_h.rvn_widget_invalidate_paint(&graph.*.base);
}

fn rvn_ng_to_canvas(graph: [*c]const rvn_node_graph_t, x: f32, y: f32) base.rvn_vec2_t {
    return base.rvn_vec2((x - graph.*.pan_x) / graph.*.draw_zoom, (y - graph.*.pan_y) / graph.*.draw_zoom);
}

/// Zooms keeping what is under a point of the widget in place.
fn rvn_ng_zoom_at(graph: [*c]rvn_node_graph_t, x: f32, y: f32, zoom_in: f32) void {
    const widget: [*c]widget_h.rvn_widget_t = &graph.*.base;
    const half_x = widget.*.rect.w * 0.5;
    const half_y = widget.*.rect.h * 0.5;
    const zoom = base.rvn_clampf(zoom_in, RVN_NG_ZOOM_MIN, RVN_NG_ZOOM_MAX);
    rvn_ng_unpin(graph);
    if (zoom == graph.*.zoom) return;
    const under_x = graph.*.center_x + (x - half_x) / graph.*.zoom;
    const under_y = graph.*.center_y + (y - half_y) / graph.*.zoom;
    rvn_ng_set_view(graph, under_x - (x - half_x) / zoom, under_y - (y - half_y) / zoom, zoom, raven.R_TRUE);
}

fn rvn_ng_frame_all(graph: [*c]rvn_node_graph_t, animate: c_int) void {
    const widget: [*c]widget_h.rvn_widget_t = &graph.*.base;
    var x0: f32 = 0.0;
    var y0: f32 = 0.0;
    var x1: f32 = 0.0;
    var y1: f32 = 0.0;
    var i: u32 = 0;
    if (widget.*.rect.w <= 1.0 or widget.*.rect.h <= 1.0) {
        graph.*.frame_pending = raven.R_TRUE;
        return;
    }
    graph.*.frame_pending = raven.R_FALSE;
    rvn_ng_geometry(graph);
    if (graph.*.node_count == 0) {
        rvn_ng_set_view(graph, 0.0, 0.0, 1.0, animate);
        return;
    }
    while (i < graph.*.node_count) : (i += 1) {
        const node: [*c]const rvn_ng_node_t = &graph.*.nodes[i];
        if (i == 0 or node.*.x < x0) x0 = node.*.x;
        if (i == 0 or node.*.y < y0) y0 = node.*.y;
        if (i == 0 or node.*.x + node.*.w > x1) x1 = node.*.x + node.*.w;
        if (i == 0 or node.*.y + node.*.h > y1) y1 = node.*.y + node.*.h;
    }
    const fit = base.rvn_minf(widget.*.rect.w / (x1 - x0 + 96.0), widget.*.rect.h / (y1 - y0 + 96.0));
    // never larger than life, and on a round value: text is sharp there
    const zoom = base.rvn_clampf(@floor(fit * 20.0) / 20.0, RVN_NG_ZOOM_MIN, 1.0);
    rvn_ng_set_view(graph, (x0 + x1) * 0.5, (y0 + y1) * 0.5, zoom, animate);
}

// ---------------------------------------------------------------------------
//  Wires
// ---------------------------------------------------------------------------

/// The curve of a wire from an output at (x0, y0) to an input at (x1, y1), its middle pushed by `sway`.
fn rvn_ng_wire(x0: f32, y0: f32, x1: f32, y1: f32, sway_x: f32, sway_y: f32, points: [*c]f32) void {
    const dx = x1 - x0;
    const dy = y1 - y0;
    const distance = @sqrt(dx * dx + dy * dy);
    // how far it leaves the pins before turning: more when it has to come back
    var pull: f32 = if (dx >= 0.0) base.rvn_clampf(dx * 0.5, 26.0, 170.0) else base.rvn_clampf(46.0 - dx * 0.35 + @abs(dy) * 0.12, 46.0, 240.0);
    // and it hangs a little, as a cable does
    const hang = base.rvn_minf(distance * 0.07, 20.0);
    pull = base.rvn_minf(pull, base.rvn_maxf(distance * 0.9, 10.0));
    points[0] = x0;
    points[1] = y0;
    points[2] = x0 + pull + sway_x;
    points[3] = y0 + hang + sway_y;
    points[4] = x1 - pull + sway_x;
    points[5] = y1 + hang + sway_y;
    points[6] = x1;
    points[7] = y1;
}

/// The part of a curve from its start to t.
fn rvn_ng_curve_start(points: [*c]const f32, t: f32, out: [*c]f32) void {
    const ax = points[0] + (points[2] - points[0]) * t;
    const ay = points[1] + (points[3] - points[1]) * t;
    const bx = points[2] + (points[4] - points[2]) * t;
    const by = points[3] + (points[5] - points[3]) * t;
    const cx = points[4] + (points[6] - points[4]) * t;
    const cy = points[5] + (points[7] - points[5]) * t;
    const abx = ax + (bx - ax) * t;
    const aby = ay + (by - ay) * t;
    const bcx = bx + (cx - bx) * t;
    const bcy = by + (cy - by) * t;
    out[0] = points[0];
    out[1] = points[1];
    out[2] = ax;
    out[3] = ay;
    out[4] = abx;
    out[5] = aby;
    out[6] = abx + (bcx - abx) * t;
    out[7] = aby + (bcy - aby) * t;
}

/// The curve of a link as it is on the canvas (with the swing its springs hold now).
fn rvn_ng_link_points(graph: [*c]const rvn_node_graph_t, link: [*c]const rvn_ng_link_t, points: [*c]f32) c_int {
    const from = rvn_ng_pin(graph, link.*.from);
    const to = rvn_ng_pin(graph, link.*.to);
    if (from == null or to == null) return raven.R_FALSE;
    const a = rvn_ng_pin_at_canvas(graph, from);
    const b = rvn_ng_pin_at_canvas(graph, to);
    rvn_ng_wire(
        a.x,
        a.y,
        b.x,
        b.y,
        if (link.*.sway_x.started != 0) link.*.sway_x.value else 0.0,
        if (link.*.sway_y.started != 0) link.*.sway_y.value else 0.0,
        points,
    );
    return raven.R_TRUE;
}

fn rvn_ng_curve_distance(points: [*c]const f32, x: f32, y: f32) f32 {
    var best: f32 = 1e30;
    var from = base.rvn_vec2(points[0], points[1]);
    var i: c_int = 1;
    while (i <= 24) : (i += 1) {
        const to = draw_h.rvn_curve_point(points, @as(f32, @floatFromInt(i)) / 24.0);
        const bx = to.x - from.x;
        const by = to.y - from.y;
        const px = x - from.x;
        const py = y - from.y;
        const h = base.rvn_clampf((px * bx + py * by) / base.rvn_maxf(bx * bx + by * by, 1e-6), 0.0, 1.0);
        const ox = px - bx * h;
        const oy = py - by * h;
        best = base.rvn_minf(best, ox * ox + oy * oy);
        from = to;
    }
    return @sqrt(best);
}

/// A wire that goes away: it is seen drawing back to its first point.
fn rvn_ng_add_ghost(graph: [*c]rvn_node_graph_t, points: [*c]const f32, from: base.rvn_color_t, to: base.rvn_color_t) void {
    if (graph.*.painted == 0) return;
    base.RVN_ARRAY_RESERVE(&graph.*.ghosts, &graph.*.ghost_cap, graph.*.ghost_count + 1);
    const index = graph.*.ghost_count;
    graph.*.ghost_count += 1;
    const ghost: [*c]rvn_ng_ghost_t = &graph.*.ghosts[index];
    ghost.* = std.mem.zeroes(rvn_ng_ghost_t);
    _ = libc.memcpy(&ghost.*.points, points, @sizeOf(@TypeOf(ghost.*.points)));
    ghost.*.from = from;
    ghost.*.to = to;
    draw_h.rvn_spring_set(&ghost.*.left, 1.0);
    widget_h.rvn_widget_invalidate_paint(&graph.*.base);
}

// ---------------------------------------------------------------------------
//  Pointing
// ---------------------------------------------------------------------------

fn rvn_ng_node_at(graph: [*c]const rvn_node_graph_t, cx: f32, cy: f32) c_int {
    var i: u32 = graph.*.node_count;
    while (i > 0) : (i -= 1) {
        const node: [*c]const rvn_ng_node_t = &graph.*.nodes[i - 1];
        if (cx >= node.*.x and cy >= node.*.y and cx < node.*.x + node.*.w and cy < node.*.y + node.*.h) return node.*.id;
    }
    return 0;
}

fn rvn_ng_pin_near(graph: [*c]const rvn_node_graph_t, cx: f32, cy: f32) c_int {
    // easy to catch, also when the graph is seen a little smaller; from far, the nodes come first
    const reach = base.rvn_minf(base.rvn_maxf(RVN_NG_PIN + 6.0, 9.0 / graph.*.draw_zoom), 16.0);
    var best = reach * reach;
    var found: c_int = 0;
    var i: u32 = 0;
    while (i < graph.*.pin_count) : (i += 1) {
        const at = rvn_ng_pin_at_canvas(graph, &graph.*.pins[i]);
        const d = (at.x - cx) * (at.x - cx) + (at.y - cy) * (at.y - cy);
        if (d < best) {
            best = d;
            found = graph.*.pins[i].id;
        }
    }
    return found;
}

fn rvn_ng_link_at(graph: [*c]const rvn_node_graph_t, cx: f32, cy: f32) c_int {
    const reach = base.rvn_maxf(5.0, 6.0 / graph.*.draw_zoom);
    var points: [8]f32 = undefined;
    var i: u32 = graph.*.link_count;
    while (i > 0) : (i -= 1) {
        const link: [*c]const rvn_ng_link_t = &graph.*.links[i - 1];
        if (link.*.id == graph.*.wire_detached and graph.*.drag == RVN_NG_DRAG_LINK) continue;
        if (rvn_ng_link_points(graph, link, &points) == 0) continue;
        if (rvn_ng_curve_distance(&points, cx, cy) <= reach) return link.*.id;
    }
    return 0;
}

/// Where the wire being pulled would go: a pin near its end, or a pin of the node it is over.
fn rvn_ng_wire_target(graph: [*c]const rvn_node_graph_t, cx: f32, cy: f32) c_int {
    const anchor = rvn_ng_pin(graph, graph.*.wire_pin);
    const reach = base.rvn_maxf(22.0, 20.0 / graph.*.draw_zoom);
    var best = reach * reach;
    var found: c_int = 0;
    var i: u32 = 0;
    if (anchor == null) return 0;
    while (i < graph.*.pin_count) : (i += 1) {
        if (rvn_ng_can_link(anchor, &graph.*.pins[i]) == 0) continue;
        const at = rvn_ng_pin_at_canvas(graph, &graph.*.pins[i]);
        const d = (at.x - cx) * (at.x - cx) + (at.y - cy) * (at.y - cy);
        if (d < best) {
            best = d;
            found = graph.*.pins[i].id;
        }
    }
    if (found != 0) return found;
    const over = rvn_ng_node_at(graph, cx, cy);
    if (over == 0 or over == anchor.*.node) return 0;
    // dropped on the node itself: its first pin that fits, a free one if there is one
    i = 0;
    while (i < graph.*.pin_count) : (i += 1) {
        const pin: [*c]const rvn_ng_pin_t = &graph.*.pins[i];
        if (pin.*.node != over or rvn_ng_can_link(anchor, pin) == 0) continue;
        if (found == 0) found = pin.*.id;
        if (pin.*.output != 0 or rvn_ng_input_link(graph, pin.*.id) == null) return pin.*.id;
    }
    return found;
}

fn rvn_ng_update_hot(widget: [*c]widget_h.rvn_widget_t, x: f32, y: f32) void {
    const graph: [*c]rvn_node_graph_t = @ptrCast(@alignCast(widget));
    const at = rvn_ng_to_canvas(graph, x, y);
    const inside = graph.*.mouse_in != 0 and x >= 0.0 and y >= 0.0 and x < widget.*.rect.w and y < widget.*.rect.h;
    const pin: c_int = if (inside) rvn_ng_pin_near(graph, at.x, at.y) else 0;
    const node: c_int = if (inside and pin == 0) rvn_ng_node_at(graph, at.x, at.y) else 0;
    const link: c_int = if (inside and pin == 0 and node == 0) rvn_ng_link_at(graph, at.x, at.y) else 0;
    if (pin != graph.*.hot_pin or node != graph.*.hot_node or link != graph.*.hot_link) {
        graph.*.hot_pin = pin;
        graph.*.hot_node = node;
        graph.*.hot_link = link;
        widget_h.rvn_widget_invalidate_paint(widget);
    }
    widget.*.cursor = if ((pin != 0 and graph.*.read_only == 0) or link != 0) raven.R_CURSOR_HAND else 0;
}

// ---------------------------------------------------------------------------
//  Life cycle and layout
// ---------------------------------------------------------------------------

fn rvn_node_graph_init(widget: [*c]widget_h.rvn_widget_t) callconv(.c) void {
    const graph: [*c]rvn_node_graph_t = @ptrCast(@alignCast(widget));
    graph.*.zoom = 1.0;
    graph.*.draw_zoom = 1.0;
    graph.*.pinned = raven.R_TRUE;
    graph.*.next_id = 1;
    graph.*.geometry_dirty = raven.R_TRUE;
    graph.*.bold = raven.R_INVALID_ID;
    widget.*.child_scale = 1.0;
}

fn rvn_node_graph_destroy(widget: [*c]widget_h.rvn_widget_t) callconv(.c) void {
    const graph: [*c]rvn_node_graph_t = @ptrCast(@alignCast(widget));
    var i: u32 = 0;
    // (the widgets inside the nodes are children: they go with the widget)
    while (i < graph.*.node_count) : (i += 1) {
        base.rvn_free(graph.*.nodes[i].name);
        base.rvn_free(graph.*.nodes[i].title);
        base.rvn_free(graph.*.nodes[i].badge);
    }
    i = 0;
    while (i < graph.*.pin_count) : (i += 1) rvn_ng_free_pin(&graph.*.pins[i]);
    i = 0;
    while (i < graph.*.type_count) : (i += 1) base.rvn_free(graph.*.types[i].name);
    base.rvn_free(graph.*.nodes);
    base.rvn_free(graph.*.pins);
    base.rvn_free(graph.*.links);
    base.rvn_free(graph.*.types);
    base.rvn_free(graph.*.ghosts);
}

fn rvn_node_graph_children_changed(widget: [*c]widget_h.rvn_widget_t) callconv(.c) void {
    const graph: [*c]rvn_node_graph_t = @ptrCast(@alignCast(widget));
    var i: u32 = 0;
    // a widget that was inside a node has been deleted or taken away
    while (i < graph.*.node_count) : (i += 1) {
        if (graph.*.nodes[i].content != null and widget_h.rvn_widget_child_index(widget, graph.*.nodes[i].content) < 0) graph.*.nodes[i].content = null;
    }
    graph.*.geometry_dirty = raven.R_TRUE;
}

fn rvn_node_graph_measure(widget: [*c]widget_h.rvn_widget_t) callconv(.c) base.rvn_vec2_t {
    const graph: [*c]rvn_node_graph_t = @ptrCast(@alignCast(widget));
    // (the widgets inside the nodes are measured there)
    graph.*.geometry_dirty = raven.R_TRUE;
    rvn_ng_geometry(graph);
    return base.rvn_vec2(480.0, 320.0);
}

fn rvn_node_graph_arrange(widget: [*c]widget_h.rvn_widget_t) callconv(.c) void {
    const graph: [*c]rvn_node_graph_t = @ptrCast(@alignCast(widget));
    var i: u32 = 0;
    rvn_ng_geometry(graph);
    if (graph.*.frame_pending != 0) rvn_ng_frame_all(graph, raven.R_FALSE);
    rvn_ng_sync(graph, null);
    while (i < graph.*.node_count) : (i += 1) {
        const node: [*c]rvn_ng_node_t = &graph.*.nodes[i];
        if (node.*.content == null or node.*.content.*.visibility == raven.R_COLLAPSED) continue;
        widget_h.rvn_widget_arrange(node.*.content, node.*.content.*.rect.x, node.*.content.*.rect.y, node.*.content_rect.w, node.*.content_rect.h);
    }
}

/// The widget inside a node only takes the mouse where its node is the one on top, and when it is large enough to be used.
fn rvn_node_graph_child_at(widget: [*c]widget_h.rvn_widget_t, child: [*c]widget_h.rvn_widget_t, x: f32, y: f32) callconv(.c) c_int {
    const graph: [*c]rvn_node_graph_t = @ptrCast(@alignCast(widget));
    const at = rvn_ng_to_canvas(graph, x, y);
    if (graph.*.drag != RVN_NG_DRAG_NONE or graph.*.draw_zoom < RVN_NG_ZOOM_USABLE) return raven.R_FALSE;
    if (rvn_ng_pin_near(graph, at.x, at.y) != 0) return raven.R_FALSE;
    const node = rvn_ng_node(graph, rvn_ng_node_at(graph, at.x, at.y));
    return @intFromBool(node != null and node.*.content == child);
}

// ---------------------------------------------------------------------------
//  Painting
// ---------------------------------------------------------------------------

fn rvn_ng_light(color: base.rvn_color_t) c_int {
    var r: f32 = undefined;
    var g: f32 = undefined;
    var b: f32 = undefined;
    var a: f32 = undefined;
    base.rvn_color_to_floats(color, &r, &g, &b, &a);
    return @intFromBool(0.2126 * r + 0.7152 * g + 0.0722 * b > 0.62);
}

fn rvn_ng_disc(painter: [*c]draw_h.RPainter, cx: f32, cy: f32, radius: f32, color: base.rvn_color_t) void {
    draw_h.rvn_paint_box(painter, base.rvn_rect(cx - radius, cy - radius, radius * 2.0, radius * 2.0), radius, color, 0.0, 0);
}

const rvn_ng_look_t = extern struct {
    text: base.rvn_color_t,
    dim: base.rvn_color_t,
    accent: base.rvn_color_t,
    body: base.rvn_color_t,
    line: base.rvn_color_t,
    size: f32,
    small: f32,
    glass: c_int,
    /// Opacity of the pulses along the wires, 0..1.
    flow: f32,
    success: base.rvn_color_t,
};

fn rvn_ng_paint_pin(graph: [*c]rvn_node_graph_t, painter: [*c]draw_h.RPainter, look: [*c]const rvn_ng_look_t, node: [*c]const rvn_ng_node_t, pin: [*c]rvn_ng_pin_t) void {
    const anchor: [*c]rvn_ng_pin_t = if (graph.*.drag == RVN_NG_DRAG_LINK) rvn_ng_pin(graph, graph.*.wire_pin) else null;
    const cx = node.*.x + pin.*.x;
    const cy = node.*.y + pin.*.y;
    const color = rvn_ng_pin_color(graph, pin);
    var target: f32 = 0.0;
    var opacity: f32 = 1.0;

    if (anchor != null) {
        // while a wire is pulled: the pins it could go to show themselves, the others step back
        if (pin.*.id == graph.*.wire_target) {
            target = 1.5;
        } else if (pin == anchor) {
            target = 0.6;
        } else if (rvn_ng_can_link(anchor, pin) != 0) {
            target = 0.5;
        } else {
            opacity = 0.3;
        }
    } else if (pin.*.id == graph.*.hot_pin and painter.*.enabled != 0 and graph.*.read_only == 0) {
        target = 1.0;
    }
    const grow = draw_h.rvn_paint_spring(painter, &pin.*.hot, target, raven.R_MOTION_BOUNCY);
    const pulse = base.rvn_clampf(draw_h.rvn_paint_spring(painter, &pin.*.pulse, 0.0, raven.R_MOTION_SMOOTH), 0.0, 1.0);
    const radius = base.rvn_maxf(RVN_NG_PIN + grow * 1.9, 2.0);

    if (grow > 0.03) {
        draw_h.rvn_paint_shadow(painter, base.rvn_rect(cx - radius, cy - radius, radius * 2.0, radius * 2.0), radius, 5.0 + grow * 5.0, base.rvn_color_fade(color, base.rvn_clampf(0.55 * grow, 0.0, 0.8) * opacity));
    }
    // a collar of the body of the node, so that the pin is cut out of its edge
    rvn_ng_disc(painter, cx, cy, radius + 2.0, base.rvn_color_fade(look.*.body | 0xFF000000, if (opacity < 1.0) @as(f32, 0.85) else @as(f32, 1.0)));
    rvn_ng_disc(painter, cx, cy, radius, base.rvn_color_fade(color, opacity));
    if (pin.*.linked == 0 and pin.*.id != graph.*.wire_target) {
        // nothing plugged in: a ring
        rvn_ng_disc(painter, cx, cy, base.rvn_maxf(radius - 2.2, 0.5), base.rvn_color_fade(base.rvn_color_mix(look.*.body | 0xFF000000, base.rvn_hex(0x000000, 255), 0.35), opacity));
    } else {
        rvn_ng_disc(painter, cx - radius * 0.22, cy - radius * 0.26, radius * 0.32, base.rvn_rgba(1.0, 1.0, 1.0, 0.45 * opacity));
    }
    if (pulse > 0.01) {
        const ring = radius + 2.0 + (1.0 - pulse) * 13.0;
        draw_h.rvn_paint_box(painter, base.rvn_rect(cx - ring, cy - ring, ring * 2.0, ring * 2.0), ring, 0, 1.6, base.rvn_color_fade(color, pulse));
    }
    if (pin.*.label != null and pin.*.label[0] != 0) {
        const text = base.rvn_color_fade(look.*.text, (if (target > 0.4) @as(f32, 1.0) else @as(f32, 0.82)) * opacity);
        if (pin.*.output != 0) {
            draw_h.rvn_paint_text_in(painter, raven.R_INVALID_ID, look.*.small, base.rvn_rect(node.*.x, cy - RVN_NG_ROW * 0.5, node.*.w - 13.0, RVN_NG_ROW), 1.0, pin.*.label, -1, text);
        } else {
            draw_h.rvn_paint_text_in(painter, raven.R_INVALID_ID, look.*.small, base.rvn_rect(node.*.x + 13.0, cy - RVN_NG_ROW * 0.5, node.*.w - 13.0, RVN_NG_ROW), 0.0, pin.*.label, -1, text);
        }
    }
}

/// One node: `canvas` paints in canvas coordinates, `layer` is the painter of
/// the widgets inside the nodes (they are laid out in the layer).
fn rvn_ng_paint_node(graph: [*c]rvn_node_graph_t, canvas: [*c]const draw_h.RPainter, layer: [*c]const draw_h.RPainter, look: [*c]const rvn_ng_look_t, node: [*c]rvn_ng_node_t) void {
    const widget: [*c]widget_h.rvn_widget_t = &graph.*.base;
    var painter: draw_h.RPainter = canvas.*;
    const first_instance = canvas.*.list.*.instance_count;
    const first_command = canvas.*.list.*.command_count;
    const rect = base.rvn_rect(node.*.x, node.*.y, node.*.w, node.*.h);
    const held = node.*.selected != 0 and graph.*.drag == RVN_NG_DRAG_MOVE and graph.*.drag_moved != 0;
    const hot = node.*.id == graph.*.hot_node and painter.enabled != 0 and graph.*.drag == RVN_NG_DRAG_NONE;
    const appear = draw_h.rvn_paint_spring_from(&painter, &node.*.appear, 1.0, raven.R_MOTION_BOUNCY);
    const lift_target: f32 = if (held) 1.0 else if (hot) 0.3 else 0.0;
    const lift = base.rvn_clampf(draw_h.rvn_paint_spring(&painter, &node.*.lift, lift_target, raven.R_MOTION_SNAPPY), 0.0, 1.3);
    const glow_target: f32 = if (node.*.selected != 0) 1.0 else 0.0;
    const glow = base.rvn_clampf(draw_h.rvn_paint_spring(&painter, &node.*.glow, glow_target, raven.R_MOTION_SNAPPY), 0.0, 1.0);
    const tone: base.rvn_color_t = if (node.*.has_color != 0) node.*.color else look.*.accent;
    const header = base.rvn_color_mix(look.*.body | 0xFF000000, tone | 0xFF000000, if (look.*.glass != 0) @as(f32, 0.72) else @as(f32, 0.8));
    var radii: [4]f32 = undefined;

    painter.clip_depth = 0;
    painter.opacity *= base.rvn_clampf(appear * 1.4, 0.0, 1.0);
    if (painter.opacity <= 0.004) return;

    // it stands above the canvas, higher while it is carried
    draw_h.rvn_paint_shadow(&painter, base.rvn_rect(rect.x, rect.y + 3.0 + lift * 7.0, rect.w, rect.h), RVN_NG_RADIUS, 12.0 + lift * 18.0, base.rvn_rgba(0.0, 0.0, 0.0, 0.34 + lift * 0.1));
    if (glow > 0.01) {
        draw_h.rvn_paint_shadow(&painter, base.rvn_rect(rect.x - 1.0, rect.y - 1.0, rect.w + 2.0, rect.h + 2.0), RVN_NG_RADIUS + 1.0, 9.0, base.rvn_color_fade(look.*.accent | 0xFF000000, 0.6 * glow));
    }
    {
        // a node that runs: a soft ring of its color breathes around it
        const active_target: f32 = if (node.*.active != 0) 1.0 else 0.0;
        const shown = base.rvn_clampf(draw_h.rvn_paint_spring(&painter, &node.*.active_shown, active_target, raven.R_MOTION_SMOOTH), 0.0, 1.0);
        if (shown > 0.01) {
            const ring: base.rvn_color_t = if (node.*.has_active_color != 0) node.*.active_color else look.*.success;
            const breath = 0.5 + 0.5 * @sin(graph.*.active_time * 4.2);
            const grow = 2.0 + 3.0 * breath;
            draw_h.rvn_paint_shadow(&painter, base.rvn_rect(rect.x - grow, rect.y - grow, rect.w + grow * 2.0, rect.h + grow * 2.0), RVN_NG_RADIUS + grow, 10.0 + 8.0 * breath, base.rvn_color_fade(ring | 0xFF000000, (0.35 + 0.35 * breath) * shown));
            draw_h.rvn_paint_box(&painter, base.rvn_rect(rect.x - 2.0, rect.y - 2.0, rect.w + 4.0, rect.h + 4.0), RVN_NG_RADIUS + 2.0, 0, 1.5, base.rvn_color_fade(ring | 0xFF000000, (0.55 + 0.45 * breath) * shown));
        }
    }
    radii[0] = RVN_NG_RADIUS;
    radii[1] = RVN_NG_RADIUS;
    radii[2] = RVN_NG_RADIUS;
    radii[3] = RVN_NG_RADIUS;
    if (look.*.glass != 0) {
        var glass: draw_h.rvn_glass_t = undefined;
        common_h.rvn_glass_style(widget, common_h.RVN_SURFACE_POPUP, 0.0, 0.0, &glass);
        glass.shadow = 0.0;
        draw_h.rvn_paint_glass(&painter, rect, &radii, &glass);
    } else {
        draw_h.rvn_paint_box(&painter, rect, RVN_NG_RADIUS, look.*.body, 0.0, 0);
    }
    // the header wears the color of the node
    radii[2] = if (node.*.h <= RVN_NG_HEADER + 9.0) RVN_NG_RADIUS - 1.0 else 0.0;
    radii[3] = radii[2];
    radii[0] = RVN_NG_RADIUS - 1.0;
    radii[1] = RVN_NG_RADIUS - 1.0;
    {
        const header_height: f32 = if (radii[2] > 0.0) node.*.h - 2.0 else RVN_NG_HEADER - 1.0;
        draw_h.rvn_paint_box4(&painter, base.rvn_rect(rect.x + 1.0, rect.y + 1.0, rect.w - 2.0, header_height), &radii, base.rvn_color_fade(header, if (look.*.glass != 0) @as(f32, 0.78) else @as(f32, 1.0)), 0.0, 0);
        // light on its upper half
        radii[2] = 0.0;
        radii[3] = 0.0;
        draw_h.rvn_paint_box4(&painter, base.rvn_rect(rect.x + 1.0, rect.y + 1.0, rect.w - 2.0, RVN_NG_HEADER * 0.48), &radii, base.rvn_rgba(1.0, 1.0, 1.0, 0.09), 0.0, 0);
        if (header_height < node.*.h - 3.0) {
            draw_h.rvn_paint_rect(&painter, base.rvn_rect(rect.x + 1.0, rect.y + RVN_NG_HEADER, rect.w - 2.0, 1.0), base.rvn_rgba(0.0, 0.0, 0.0, 0.28));
        }
    }
    const title: [*c]const u8 = if (node.*.title != null) node.*.title else "";
    draw_h.rvn_paint_text_in(&painter, graph.*.bold, look.*.size, base.rvn_rect(rect.x + 13.0, rect.y + 1.0, rect.w - 26.0, RVN_NG_HEADER - 1.0), 0.0, title, -1, if (rvn_ng_light(header) != 0) base.rvn_hex(0x14151A, 255) else base.rvn_hex(0xFFFFFF, 255));
    // its edge: a hairline, the accent when it is selected
    radii[0] = RVN_NG_RADIUS;
    radii[1] = RVN_NG_RADIUS;
    radii[2] = RVN_NG_RADIUS;
    radii[3] = RVN_NG_RADIUS;
    draw_h.rvn_paint_box4(&painter, rect, &radii, 0, 1.0 + glow * 0.8, base.rvn_color_mix(look.*.line, look.*.accent | 0xFF000000, glow));
    {
        // the badge: a pill astride the top right corner, it pops when its text appears
        const badge_target: f32 = if (node.*.badge != null and node.*.badge[0] != 0) 1.0 else 0.0;
        const shown = base.rvn_clampf(draw_h.rvn_paint_spring(&painter, &node.*.badge_shown, badge_target, raven.R_MOTION_BOUNCY), 0.0, 1.2);
        if (shown > 0.02 and node.*.badge != null) {
            const text_w = common_h.rvn_widget_text_width(widget, raven.R_INVALID_ID, look.*.small, node.*.badge);
            const bh = 18.0 * shown;
            const bw = base.rvn_maxf(bh, text_w + 12.0) * base.rvn_minf(1.0, shown);
            const pill = base.rvn_rect(rect.x + rect.w - bw * 0.5 - 6.0, rect.y - bh * 0.5, bw, bh);
            draw_h.rvn_paint_shadow(&painter, base.rvn_rect(pill.x, pill.y + 1.5, pill.w, pill.h), bh * 0.5, 6.0, base.rvn_rgba(0.0, 0.0, 0.0, 0.3));
            draw_h.rvn_paint_box(&painter, pill, bh * 0.5, look.*.accent | 0xFF000000, 1.0, look.*.body | 0xFF000000);
            if (shown > 0.6) {
                draw_h.rvn_paint_text_in(&painter, graph.*.bold, look.*.small, pill, 0.5, node.*.badge, -1, if (rvn_ng_light(look.*.accent) != 0) base.rvn_hex(0x14151A, 255) else base.rvn_hex(0xFFFFFF, 255));
            }
        }
    }

    var k: u32 = 0;
    while (k < graph.*.pin_count) : (k += 1) {
        if (graph.*.pins[k].node == node.*.id) rvn_ng_paint_pin(graph, &painter, look, node, &graph.*.pins[k]);
    }
    if (node.*.content != null and node.*.content.*.visibility == raven.R_VISIBLE) {
        var inner: draw_h.RPainter = layer.*;
        inner.opacity = painter.opacity;
        inner.clip_depth = 0;
        widget_h.rvn_widget_paint(node.*.content, @ptrCast(&inner));
    }

    // it pops in, and swells a little while it is carried
    const scale: f32 = (0.86 + 0.14 * appear) * (1.0 + 0.012 * lift);
    if (scale != 1.0) {
        draw_h.rvn_drawlist_transform(canvas.*.list, first_instance, first_command, scale, scale, (canvas.*.ox + rect.x + rect.w * 0.5) * canvas.*.scale, (canvas.*.oy + rect.y + rect.h * 0.5) * canvas.*.scale, 0.0, 0.0, canvas.*.clip);
    }
}

fn rvn_ng_paint_curve(painter: [*c]draw_h.RPainter, look: [*c]const rvn_ng_look_t, points: [*c]const f32, from: base.rvn_color_t, to: base.rvn_color_t, emphasis: f32, selected: c_int, flow: f32, time: f32) void {
    var curve: draw_h.rvn_curve_t = undefined;
    const dx = points[6] - points[0];
    const dy = points[7] - points[1];
    const length = @sqrt(dx * dx + dy * dy) + @abs(points[2] - points[0]) * 0.4;
    curve = std.mem.zeroes(draw_h.rvn_curve_t);
    if (selected != 0) {
        // a selected wire has a sleeve of the color of the text
        curve.thickness = 6.6;
        curve.from = base.rvn_color_fade(look.*.text | 0xFF000000, 0.92);
        curve.to = curve.from;
        draw_h.rvn_paint_curve(painter, points, &curve);
    }
    curve.thickness = 2.6 + emphasis * 1.0;
    curve.from = from;
    curve.to = to;
    curve.halo = 6.0 + emphasis * 5.0;
    curve.halo_opacity = 0.22 + emphasis * 0.26;
    if (flow > 0.01) {
        curve.pulses = base.rvn_maxf(length / 120.0, 0.6);
        curve.phase = time * 0.85;
        curve.pulse_strength = flow;
    }
    draw_h.rvn_paint_curve(painter, points, &curve);
}

/// Moves the swing of a wire: its middle is left behind by what its ends just did, and comes back.
fn rvn_ng_swing(painter: [*c]draw_h.RPainter, sway_x: [*c]raven.RSpring, sway_y: [*c]raven.RSpring, last_x: [*c]f32, last_y: [*c]f32, has_last: [*c]c_int, x0: f32, y0: f32, x1: f32, y1: f32, out_x: [*c]f32, out_y: [*c]f32) void {
    const middle_x = (x0 + x1) * 0.5;
    const middle_y = (y0 + y1) * 0.5;
    out_x.* = draw_h.rvn_paint_spring(painter, sway_x, 0.0, raven.R_MOTION_WOBBLY);
    out_y.* = draw_h.rvn_paint_spring(painter, sway_y, 0.0, raven.R_MOTION_WOBBLY);
    if (has_last.* != 0) {
        const dx = middle_x - last_x.*;
        const dy = middle_y - last_y.*;
        if (@abs(dx) + @abs(dy) > 0.01) {
            sway_x.*.value = base.rvn_clampf(sway_x.*.value - dx * 0.8, -70.0, 70.0);
            sway_y.*.value = base.rvn_clampf(sway_y.*.value - dy * 0.8, -70.0, 70.0);
            out_x.* = sway_x.*.value;
            out_y.* = sway_y.*.value;
            draw_h.rvn_paint_keep_animating(painter);
        }
    }
    last_x.* = middle_x;
    last_y.* = middle_y;
    has_last.* = raven.R_TRUE;
}

fn rvn_node_graph_paint(widget: [*c]widget_h.rvn_widget_t, painter_arg: ?*raven.RPainter) callconv(.c) void {
    const graph: [*c]rvn_node_graph_t = @ptrCast(@alignCast(widget));
    const painter: [*c]draw_h.RPainter = @ptrCast(@alignCast(painter_arg.?));
    var look: rvn_ng_look_t = undefined;
    const bounds = base.rvn_rect(0.0, 0.0, widget.*.rect.w, widget.*.rect.h);
    const radius = widget_h.rvn_widget_metric(widget, raven.R_METRIC_CORNER_RADIUS);
    var i: u32 = 0;

    rvn_ng_geometry(graph);
    rvn_ng_sync(graph, painter);
    const zoom = graph.*.draw_zoom;

    look = std.mem.zeroes(rvn_ng_look_t);
    look.text = widget_h.rvn_widget_text_color(widget, @ptrCast(painter));
    look.dim = base.rvn_color_fade(look.text, 0.55);
    look.accent = widget_h.rvn_widget_color(widget, raven.R_COLOR_ACCENT);
    look.body = widget_h.rvn_widget_color(widget, raven.R_COLOR_POPUP);
    look.line = widget_h.rvn_widget_color(widget, raven.R_COLOR_POPUP_BORDER);
    look.size = common_h.rvn_widget_font_size(widget, 0.0);
    look.small = @floor(look.size * 0.9);
    look.glass = widget_h.rvn_widget_glass(widget);
    look.success = widget_h.rvn_widget_color(widget, raven.R_COLOR_SUCCESS);
    {
        // the ring of the active nodes breathes: the window keeps drawing while one runs
        var any_active: c_int = raven.R_FALSE;
        while (i < graph.*.node_count) : (i += 1) any_active = @intFromBool(any_active != 0 or graph.*.nodes[i].active != 0);
        if (any_active != 0 and painter.*.enabled != 0) {
            graph.*.active_time += painter.*.dt;
            if (graph.*.active_time > 4096.0) graph.*.active_time -= 4096.0;
            draw_h.rvn_paint_keep_animating(painter);
        }
    }

    // the pulses run while the pointer is over the graph, or always, or never
    var flow_target: f32 = if (graph.*.flow_mode == RVN_NG_FLOW_ALWAYS or (graph.*.flow_mode == RVN_NG_FLOW_AUTO and (graph.*.mouse_in != 0 or graph.*.drag != RVN_NG_DRAG_NONE))) 1.0 else 0.0;
    if (painter.*.enabled == 0 or graph.*.link_count == 0) flow_target = 0.0;
    look.flow = base.rvn_clampf(draw_h.rvn_paint_spring(painter, &graph.*.flow, flow_target, raven.R_MOTION_SMOOTH), 0.0, 1.0);
    if (look.flow > 0.01) {
        graph.*.flow_time += painter.*.dt;
        if (graph.*.flow_time > 4096.0) graph.*.flow_time -= 4096.0;
        if (flow_target > 0.0) draw_h.rvn_paint_keep_animating(painter);
    }

    // ---- the canvas ----
    draw_h.rvn_paint_box(painter, bounds, radius, widget_h.rvn_widget_color(widget, raven.R_COLOR_INPUT), 1.0, widget_h.rvn_widget_color(widget, raven.R_COLOR_BORDER));
    draw_h.rvn_paint_push_clip(painter, base.rvn_rect(1.0, 1.0, bounds.w - 2.0, bounds.h - 2.0));
    if (graph.*.grid_hidden == 0) {
        // dots; when they get too close, every other one goes
        var step: f32 = RVN_NG_GRID * zoom;
        const every: c_int = 4;
        while (step < 16.0) step *= 2.0;
        const first_x = graph.*.pan_x - @floor(graph.*.pan_x / step) * step - step;
        const first_y = graph.*.pan_y - @floor(graph.*.pan_y / step) * step - step;
        var row: c_int = @intFromFloat(@floor((first_y - graph.*.pan_y) / step + 0.5));
        var y: f32 = first_y;
        while (y < bounds.h + step) : ({
            y += step;
            row += 1;
        }) {
            var column: c_int = @intFromFloat(@floor((first_x - graph.*.pan_x) / step + 0.5));
            var x: f32 = first_x;
            while (x < bounds.w + step) : ({
                x += step;
                column += 1;
            }) {
                const major = @rem(column, every) == 0 and @rem(row, every) == 0;
                const half: f32 = if (major) 1.5 else 1.0;
                draw_h.rvn_paint_box(painter, base.rvn_rect(@floor(x) - half, @floor(y) - half, half * 2.0, half * 2.0), half, base.rvn_color_fade(look.text, if (major) @as(f32, 0.22) else @as(f32, 0.1)), 0.0, 0);
            }
        }
    }

    // ---- what zooms ----
    // drawn at the size of the zoom asked for (rounded: few sizes of text), then scaled by what is left
    const raster = base.rvn_clampf(@floor(graph.*.zoom * 20.0 + 0.5) / 20.0, RVN_NG_ZOOM_MIN, RVN_NG_ZOOM_MAX);
    const rest = zoom / raster;
    const clip = painter.*.clip;
    var layer: draw_h.RPainter = painter.*;
    layer.clip_depth = 0;
    layer.scale = painter.*.scale * raster;
    layer.ox = painter.*.ox / zoom;
    layer.oy = painter.*.oy / zoom;
    layer.clip = base.rvn_box(clip.x0 / rest, clip.y0 / rest, clip.x1 / rest, clip.y1 / rest);
    var canvas: draw_h.RPainter = layer;
    canvas.ox += graph.*.pan_x / zoom;
    canvas.oy += graph.*.pan_y / zoom;
    const first_instance = painter.*.list.*.instance_count;
    const first_command = painter.*.list.*.command_count;

    i = 0;
    while (i < graph.*.pin_count) : (i += 1) graph.*.pins[i].linked = raven.R_FALSE;
    i = 0;
    while (i < graph.*.link_count) : (i += 1) {
        const link: [*c]rvn_ng_link_t = &graph.*.links[i];
        const from = rvn_ng_pin(graph, link.*.from);
        const to = rvn_ng_pin(graph, link.*.to);
        var points: [8]f32 = undefined;
        var part: [8]f32 = undefined;
        var sway_x: f32 = undefined;
        var sway_y: f32 = undefined;
        if (from == null or to == null) continue;
        if (link.*.id == graph.*.wire_detached and graph.*.drag == RVN_NG_DRAG_LINK) continue;
        from.*.linked = raven.R_TRUE;
        to.*.linked = raven.R_TRUE;
        const a = rvn_ng_pin_at_canvas(graph, from);
        const b = rvn_ng_pin_at_canvas(graph, to);
        rvn_ng_swing(painter, &link.*.sway_x, &link.*.sway_y, &link.*.last_x, &link.*.last_y, &link.*.has_last, a.x, a.y, b.x, b.y, &sway_x, &sway_y);
        rvn_ng_wire(a.x, a.y, b.x, b.y, sway_x, sway_y, &points);
        const hover_target: f32 = if ((link.*.id == graph.*.hot_link and graph.*.drag == RVN_NG_DRAG_NONE) or link.*.selected != 0) 1.0 else 0.0;
        const hover = draw_h.rvn_paint_spring(painter, &link.*.hover, hover_target, raven.R_MOTION_SNAPPY);
        const grow = base.rvn_clampf(draw_h.rvn_paint_spring_from(painter, &link.*.grow, 1.0, raven.R_MOTION_SMOOTH), 0.0, 1.0);
        if (grow < 0.995) {
            rvn_ng_curve_start(&points, grow, &part);
            rvn_ng_paint_curve(&canvas, &look, &part, rvn_ng_pin_color(graph, from), base.rvn_color_mix(rvn_ng_pin_color(graph, from), rvn_ng_pin_color(graph, to), grow), hover, link.*.selected, 0.0, 0.0);
        } else {
            rvn_ng_paint_curve(&canvas, &look, &points, rvn_ng_pin_color(graph, from), rvn_ng_pin_color(graph, to), hover, link.*.selected, look.flow, graph.*.flow_time);
        }
    }
    // wires that were let go draw back into their pin
    i = graph.*.ghost_count;
    while (i > 0) : (i -= 1) {
        const ghost: [*c]rvn_ng_ghost_t = &graph.*.ghosts[i - 1];
        const left = draw_h.rvn_paint_spring(painter, &ghost.*.left, 0.0, raven.R_MOTION_SNAPPY);
        var part: [8]f32 = undefined;
        if (left < 0.03) {
            _ = libc.memmove(ghost, ghost + 1, @as(usize, graph.*.ghost_count - i) * @sizeOf(rvn_ng_ghost_t));
            graph.*.ghost_count -= 1;
            continue;
        }
        rvn_ng_curve_start(&ghost.*.points, base.rvn_clampf(left, 0.0, 1.0), &part);
        rvn_ng_paint_curve(&canvas, &look, &part, base.rvn_color_fade(ghost.*.from, left), base.rvn_color_fade(base.rvn_color_mix(ghost.*.from, ghost.*.to, left), left), 0.0, raven.R_FALSE, 0.0, 0.0);
    }

    i = 0;
    while (i < graph.*.node_count) : (i += 1) {
        const node: [*c]rvn_ng_node_t = &graph.*.nodes[i];
        const seen = draw_h.rvn_paint_snap(&canvas, base.rvn_rect(node.*.x - 40.0, node.*.y - 40.0, node.*.w + 80.0, node.*.h + 90.0));
        if (base.rvn_box_overlaps(seen, canvas.clip) == 0) {
            // (out of sight: it is not animated, only kept up to date)
            if (node.*.appear.started == 0) draw_h.rvn_spring_set(&node.*.appear, 1.0);
            continue;
        }
        rvn_ng_paint_node(graph, &canvas, &layer, &look, node);
    }

    // the wire being pulled goes over the nodes: its end is what is looked at
    if (graph.*.drag == RVN_NG_DRAG_LINK) {
        const anchor = rvn_ng_pin(graph, graph.*.wire_pin);
        const target = rvn_ng_pin(graph, graph.*.wire_target);
        if (anchor != null) {
            const fixed = rvn_ng_pin_at_canvas(graph, anchor);
            const snap_target: f32 = if (target != null) 1.0 else 0.0;
            const snap = base.rvn_clampf(draw_h.rvn_paint_spring(painter, &graph.*.wire_snap, snap_target, raven.R_MOTION_SNAPPY), 0.0, 1.0);
            var end_x = graph.*.wire_x;
            var end_y = graph.*.wire_y;
            var points: [8]f32 = undefined;
            var sway_x: f32 = undefined;
            var sway_y: f32 = undefined;
            const color = rvn_ng_pin_color(graph, anchor);
            const other = if (target != null) rvn_ng_pin_color(graph, target) else color;
            if (target != null) {
                const at = rvn_ng_pin_at_canvas(graph, target);
                end_x += (at.x - end_x) * snap;
                end_y += (at.y - end_y) * snap;
            }
            rvn_ng_swing(painter, &graph.*.wire_sway_x, &graph.*.wire_sway_y, &graph.*.wire_last_x, &graph.*.wire_last_y, &graph.*.wire_has_last, fixed.x, fixed.y, end_x, end_y, &sway_x, &sway_y);
            if (anchor.*.output != 0) {
                rvn_ng_wire(fixed.x, fixed.y, end_x, end_y, sway_x, sway_y, &points);
                rvn_ng_paint_curve(&canvas, &look, &points, color, other, 0.6 + snap * 0.4, raven.R_FALSE, 1.0, graph.*.flow_time);
            } else {
                rvn_ng_wire(end_x, end_y, fixed.x, fixed.y, sway_x, sway_y, &points);
                rvn_ng_paint_curve(&canvas, &look, &points, other, color, 0.6 + snap * 0.4, raven.R_FALSE, 1.0, graph.*.flow_time);
            }
            if (target == null) {
                // the loose end
                rvn_ng_disc(&canvas, end_x, end_y, 4.5, color);
                rvn_ng_disc(&canvas, end_x, end_y, 2.0, base.rvn_rgba(1.0, 1.0, 1.0, 0.85));
            }
            graph.*.flow_time += if (look.flow > 0.01) @as(f32, 0.0) else painter.*.dt;
            draw_h.rvn_paint_keep_animating(painter);
        }
    }

    if (rest != 1.0) {
        draw_h.rvn_drawlist_transform(painter.*.list, first_instance, first_command, rest, rest, 0.0, 0.0, 0.0, 0.0, clip);
    }

    if (graph.*.drag == RVN_NG_DRAG_BOX and graph.*.drag_moved != 0) {
        draw_h.rvn_paint_box(painter, graph.*.box, 4.0, base.rvn_color_fade(look.accent, 0.14), 1.0, base.rvn_color_fade(look.accent, 0.85));
    }
    draw_h.rvn_paint_pop_clip(painter);
    graph.*.painted = raven.R_TRUE;
}

fn rvn_node_graph_paint_overlay(widget: [*c]widget_h.rvn_widget_t, painter: ?*raven.RPainter) callconv(.c) void {
    common_h.rvn_paint_focus(widget, painter, widget_h.rvn_widget_metric(widget, raven.R_METRIC_CORNER_RADIUS));
}

// ---------------------------------------------------------------------------
//  What the user does
// ---------------------------------------------------------------------------

fn rvn_ng_notify(widget: [*c]widget_h.rvn_widget_t, callback: raven.RNodeGraphItemCallback, user: ?*anyopaque, item: c_int) void {
    if (callback) |cb| {
        if (common_h.rvn_widget_alive(widget) != 0) cb(widget.*.id, item, user);
    }
}

/// Returns R_TRUE when the selection changed.
fn rvn_ng_select_only(graph: [*c]rvn_node_graph_t, node_id: c_int, link_id: c_int) c_int {
    var changed: c_int = raven.R_FALSE;
    var i: u32 = 0;
    while (i < graph.*.node_count) : (i += 1) {
        const selected: c_int = @intFromBool(graph.*.nodes[i].id == node_id);
        changed = @intFromBool(changed != 0 or selected != graph.*.nodes[i].selected);
        graph.*.nodes[i].selected = selected;
    }
    i = 0;
    while (i < graph.*.link_count) : (i += 1) {
        const selected: c_int = @intFromBool(graph.*.links[i].id == link_id);
        changed = @intFromBool(changed != 0 or selected != graph.*.links[i].selected);
        graph.*.links[i].selected = selected;
    }
    if (changed != 0) widget_h.rvn_widget_invalidate_paint(&graph.*.base);
    return changed;
}

/// The user removes a link: the application is told first, and a ghost of the wire draws back.
fn rvn_ng_user_unlink(widget: [*c]widget_h.rvn_widget_t, id: c_int) void {
    const graph: [*c]rvn_node_graph_t = @ptrCast(@alignCast(widget));
    var link = rvn_ng_link(graph, id);
    var points: [8]f32 = undefined;
    if (link == null) return;
    rvn_ng_notify(widget, graph.*.unlinked_callback, graph.*.unlinked_user, id);
    if (common_h.rvn_widget_alive(widget) == 0) return;
    link = rvn_ng_link(graph, id);
    if (link == null) return;
    if (rvn_ng_link_points(graph, link, &points) != 0) {
        rvn_ng_add_ghost(graph, &points, rvn_ng_pin_color(graph, rvn_ng_pin(graph, link.*.from)), rvn_ng_pin_color(graph, rvn_ng_pin(graph, link.*.to)));
    }
    rvn_ng_remove_link(graph, id);
}

/// The user links two pins. Returns the link, or 0 when the application refused.
fn rvn_ng_user_link(widget: [*c]widget_h.rvn_widget_t, pin_a: c_int, pin_b: c_int) c_int {
    const graph: [*c]rvn_node_graph_t = @ptrCast(@alignCast(widget));
    var a = rvn_ng_pin(graph, pin_a);
    var b = rvn_ng_pin(graph, pin_b);
    var old: [*c]rvn_ng_link_t = undefined;
    if (rvn_ng_can_link(a, b) == 0) return 0;
    const output: c_int = if (a.*.output != 0) a.*.id else b.*.id;
    const input: c_int = if (a.*.output != 0) b.*.id else a.*.id;
    if (graph.*.connect_callback) |connect| {
        if (connect(widget.*.id, output, input, graph.*.connect_user) == 0) return 0;
    }
    if (common_h.rvn_widget_alive(widget) == 0 or rvn_ng_can_link(rvn_ng_pin(graph, output), rvn_ng_pin(graph, input)) == 0) return 0;
    old = rvn_ng_input_link(graph, input);
    if (old != null and rvn_ng_pin(graph, input).*.multiple != 0) {
        // an input of several links: only the same link already there is reused
        var k: u32 = 0;
        while (k < graph.*.link_count) : (k += 1) {
            if (graph.*.links[k].to == input and graph.*.links[k].from == output) return graph.*.links[k].id;
        }
        old = null;
    }
    if (old != null and old.*.from == output) return old.*.id;
    if (old != null) {
        rvn_ng_user_unlink(widget, old.*.id);
        if (common_h.rvn_widget_alive(widget) == 0 or rvn_ng_pin(graph, output) == null or rvn_ng_pin(graph, input) == null) return 0;
    }
    const id = rvn_ng_add_link(graph, output, input, raven.R_FALSE);
    a = rvn_ng_pin(graph, output);
    b = rvn_ng_pin(graph, input);
    if (graph.*.painted != 0) {
        // a ring leaves both pins
        a.*.pulse.value = 1.0;
        a.*.pulse.started = raven.R_TRUE;
        b.*.pulse.value = 1.0;
        b.*.pulse.started = raven.R_TRUE;
    }
    rvn_ng_notify(widget, graph.*.linked_callback, graph.*.linked_user, id);
    if (common_h.rvn_widget_alive(widget) != 0) widget_h.rvn_widget_fire_action(widget);
    return id;
}

fn rvn_ng_remove_selected(widget: [*c]widget_h.rvn_widget_t) void {
    const graph: [*c]rvn_node_graph_t = @ptrCast(@alignCast(widget));
    var any: c_int = raven.R_FALSE;
    var i: u32 = 0;
    while (i < graph.*.link_count) : (i +%= 1) {
        if (graph.*.links[i].selected == 0) continue;
        graph.*.links[i].selected = raven.R_FALSE;
        rvn_ng_user_unlink(widget, graph.*.links[i].id);
        if (common_h.rvn_widget_alive(widget) == 0) return;
        any = raven.R_TRUE;
        i = RVN_NG_RESTART;
    }
    // nodes only go when the application listens: it holds what they stand for
    if (graph.*.removed_callback != null) {
        i = 0;
        while (i < graph.*.node_count) : (i +%= 1) {
            const id = graph.*.nodes[i].id;
            var k: u32 = 0;
            if (graph.*.nodes[i].selected == 0 or graph.*.nodes[i].undeletable != 0) continue;
            graph.*.nodes[i].selected = raven.R_FALSE;
            rvn_ng_notify(widget, graph.*.removed_callback, graph.*.removed_user, id);
            if (common_h.rvn_widget_alive(widget) == 0) return;
            // its links go with it: the application hears about each
            while (k < graph.*.link_count) : (k +%= 1) {
                const from = rvn_ng_pin(graph, graph.*.links[k].from);
                const to = rvn_ng_pin(graph, graph.*.links[k].to);
                if ((from != null and from.*.node == id) or (to != null and to.*.node == id)) {
                    rvn_ng_user_unlink(widget, graph.*.links[k].id);
                    if (common_h.rvn_widget_alive(widget) == 0) return;
                    k = RVN_NG_RESTART;
                }
            }
            rvn_ng_remove_node(graph, id);
            any = raven.R_TRUE;
            i = RVN_NG_RESTART;
        }
    }
    if (any != 0) {
        widget_h.rvn_widget_invalidate_paint(widget);
        rvn_ng_notify(widget, graph.*.selection_callback, graph.*.selection_user, 0);
        if (common_h.rvn_widget_alive(widget) != 0) widget_h.rvn_widget_fire_action(widget);
    }
}

fn rvn_ng_begin_wire(widget: [*c]widget_h.rvn_widget_t, pin_id: c_int, cx: f32, cy: f32) void {
    const graph: [*c]rvn_node_graph_t = @ptrCast(@alignCast(widget));
    const pin = rvn_ng_pin(graph, pin_id);
    // (an input of several links starts a new wire: which one to pick up would be a guess)
    const link: [*c]rvn_ng_link_t = if (pin != null and pin.*.output == 0 and pin.*.multiple == 0) rvn_ng_input_link(graph, pin_id) else null;
    // an input that is linked gives the end of its wire: it can be plugged somewhere else, or let go
    graph.*.wire_detached = if (link != null) link.*.id else 0;
    graph.*.wire_pin = if (link != null) link.*.from else pin_id;
    graph.*.wire_target = if (link != null) pin_id else 0;
    graph.*.wire_x = cx;
    graph.*.wire_y = cy;
    graph.*.wire_has_last = raven.R_FALSE;
    draw_h.rvn_spring_set(&graph.*.wire_snap, if (link != null) 1.0 else 0.0);
    draw_h.rvn_spring_set(&graph.*.wire_sway_x, 0.0);
    draw_h.rvn_spring_set(&graph.*.wire_sway_y, 0.0);
    graph.*.drag = RVN_NG_DRAG_LINK;
    widget_h.rvn_widget_capture_mouse(widget);
    widget_h.rvn_widget_invalidate_paint(widget);
}

/// The curve of the wire being pulled, from the pin it is attached to.
fn rvn_ng_wire_ghost(graph: [*c]rvn_node_graph_t) void {
    const anchor = rvn_ng_pin(graph, graph.*.wire_pin);
    var points: [8]f32 = undefined;
    if (anchor == null) return;
    const fixed = rvn_ng_pin_at_canvas(graph, anchor);
    const color = rvn_ng_pin_color(graph, anchor);
    if (anchor.*.output != 0) {
        rvn_ng_wire(fixed.x, fixed.y, graph.*.wire_x, graph.*.wire_y, graph.*.wire_sway_x.value, graph.*.wire_sway_y.value, &points);
    } else {
        // (a ghost draws back to its first point: the pin)
        var back: [8]f32 = undefined;
        var i: usize = 0;
        rvn_ng_wire(graph.*.wire_x, graph.*.wire_y, fixed.x, fixed.y, graph.*.wire_sway_x.value, graph.*.wire_sway_y.value, &back);
        while (i < 4) : (i += 1) {
            points[i * 2] = back[(3 - i) * 2];
            points[i * 2 + 1] = back[(3 - i) * 2 + 1];
        }
    }
    rvn_ng_add_ghost(graph, &points, color, color);
}

fn rvn_ng_end_drag(widget: [*c]widget_h.rvn_widget_t, cancel: c_int) void {
    const graph: [*c]rvn_node_graph_t = @ptrCast(@alignCast(widget));
    const drag = graph.*.drag;
    const moved = graph.*.drag_moved;
    var i: u32 = 0;

    graph.*.drag = RVN_NG_DRAG_NONE;
    graph.*.drag_moved = raven.R_FALSE;
    widget_h.rvn_widget_release_mouse(widget);
    widget_h.rvn_widget_invalidate_paint(widget);

    if (drag == RVN_NG_DRAG_MOVE) {
        if (cancel != 0) {
            while (i < graph.*.node_count) : (i += 1) {
                if (graph.*.nodes[i].selected == 0) continue;
                graph.*.nodes[i].x = graph.*.nodes[i].from_x;
                graph.*.nodes[i].y = graph.*.nodes[i].from_y;
            }
            rvn_ng_place_contents(graph);
            return;
        }
        if (moved == 0) return;
        i = 0;
        while (i < graph.*.node_count) : (i +%= 1) {
            const node: [*c]rvn_ng_node_t = &graph.*.nodes[i];
            const id = node.*.id;
            if (node.*.selected == 0 or (node.*.x == node.*.from_x and node.*.y == node.*.from_y)) continue;
            node.*.from_x = node.*.x;
            node.*.from_y = node.*.y;
            rvn_ng_notify(widget, graph.*.moved_callback, graph.*.moved_user, id);
            if (common_h.rvn_widget_alive(widget) == 0) return;
            i = RVN_NG_RESTART;
        }
        widget_h.rvn_widget_fire_action(widget);
    } else if (drag == RVN_NG_DRAG_LINK) {
        const detached = graph.*.wire_detached;
        const target: c_int = if (cancel != 0) 0 else graph.*.wire_target;
        const anchor = graph.*.wire_pin;
        const old = rvn_ng_link(graph, detached);
        graph.*.wire_detached = 0;
        graph.*.wire_target = 0;
        if (old != null and (cancel != 0 or target == old.*.to)) return;
        if (old != null) {
            // the wire left its input
            const ghosts = graph.*.ghost_count;
            rvn_ng_user_unlink(widget, detached);
            if (common_h.rvn_widget_alive(widget) == 0) return;
            // (the wire that draws back is the one that was pulled, not the link where it was)
            if (graph.*.ghost_count > ghosts) graph.*.ghost_count = ghosts;
        }
        if (target == 0 or rvn_ng_user_link(widget, anchor, target) == 0) {
            if (common_h.rvn_widget_alive(widget) != 0) rvn_ng_wire_ghost(graph);
            if (old != null and common_h.rvn_widget_alive(widget) != 0) widget_h.rvn_widget_fire_action(widget);
        }
    } else if (drag == RVN_NG_DRAG_BOX) {
        var changed: c_int = raven.R_FALSE;
        if (cancel != 0) {
            while (i < graph.*.node_count) : (i += 1) graph.*.nodes[i].selected = graph.*.nodes[i].from_selected;
            return;
        }
        if (moved == 0 and graph.*.box_add == 0) {
            // a click on the empty canvas forgets the selection
            i = 0;
            while (i < graph.*.node_count) : (i += 1) graph.*.nodes[i].selected = raven.R_FALSE;
            i = 0;
            while (i < graph.*.link_count) : (i += 1) {
                changed = @intFromBool(changed != 0 or graph.*.links[i].selected != 0);
                graph.*.links[i].selected = raven.R_FALSE;
            }
        }
        i = 0;
        while (i < graph.*.node_count) : (i += 1) changed = @intFromBool(changed != 0 or graph.*.nodes[i].selected != graph.*.nodes[i].from_selected);
        if (changed != 0) rvn_ng_notify(widget, graph.*.selection_callback, graph.*.selection_user, 0);
    } else if (drag == RVN_NG_DRAG_PAN) {
        // let go while moving: the canvas slides a little further
        if (cancel == 0 and moved != 0 and thread_h.rvn_clock_seconds() - graph.*.pan_clock < 0.06) {
            graph.*.center_x -= base.rvn_clampf(graph.*.pan_speed_x * 0.14, -400.0, 400.0) / graph.*.zoom;
            graph.*.center_y -= base.rvn_clampf(graph.*.pan_speed_y * 0.14, -400.0, 400.0) / graph.*.zoom;
        }
    }
}

fn rvn_ng_drag_to(widget: [*c]widget_h.rvn_widget_t, x: f32, y: f32) void {
    const graph: [*c]rvn_node_graph_t = @ptrCast(@alignCast(widget));
    const at = rvn_ng_to_canvas(graph, x, y);
    var i: u32 = 0;
    if (graph.*.drag_moved == 0 and @abs(x - graph.*.press_x) + @abs(y - graph.*.press_y) > 3.0) graph.*.drag_moved = raven.R_TRUE;
    switch (graph.*.drag) {
        RVN_NG_DRAG_MOVE => {
            if (graph.*.drag_moved == 0) return;
            while (i < graph.*.node_count) : (i += 1) {
                const node: [*c]rvn_ng_node_t = &graph.*.nodes[i];
                if (node.*.selected == 0) continue;
                node.*.x = node.*.from_x + (at.x - graph.*.press_cx);
                node.*.y = node.*.from_y + (at.y - graph.*.press_cy);
            }
            rvn_ng_place_contents(graph);
        },
        RVN_NG_DRAG_LINK => {
            graph.*.wire_x = at.x;
            graph.*.wire_y = at.y;
            graph.*.wire_target = rvn_ng_wire_target(graph, at.x, at.y);
        },
        RVN_NG_DRAG_BOX => {
            const x0 = base.rvn_minf(graph.*.press_x, x);
            const y0 = base.rvn_minf(graph.*.press_y, y);
            const x1 = base.rvn_maxf(graph.*.press_x, x);
            const y1 = base.rvn_maxf(graph.*.press_y, y);
            const a = rvn_ng_to_canvas(graph, x0, y0);
            const b = rvn_ng_to_canvas(graph, x1, y1);
            graph.*.box = base.rvn_rect(x0, y0, x1 - x0, y1 - y0);
            if (graph.*.drag_moved == 0) return;
            while (i < graph.*.node_count) : (i += 1) {
                const node: [*c]rvn_ng_node_t = &graph.*.nodes[i];
                const inside = node.*.x < b.x and node.*.x + node.*.w > a.x and node.*.y < b.y and node.*.y + node.*.h > a.y;
                node.*.selected = @intFromBool(inside or (graph.*.box_add != 0 and node.*.from_selected != 0));
            }
        },
        RVN_NG_DRAG_PAN => {
            const now = thread_h.rvn_clock_seconds();
            const before_x = graph.*.center_x;
            const before_y = graph.*.center_y;
            const dt: f32 = @floatCast(now - graph.*.pan_clock);
            graph.*.center_x = graph.*.pan_from_x - (x - graph.*.press_x) / graph.*.zoom;
            graph.*.center_y = graph.*.pan_from_y - (y - graph.*.press_y) / graph.*.zoom;
            // the canvas is held: it follows the hand, without easing
            draw_h.rvn_spring_set(&graph.*.shown_x, graph.*.center_x);
            draw_h.rvn_spring_set(&graph.*.shown_y, graph.*.center_y);
            if (dt > 0.001) {
                graph.*.pan_speed_x = -(graph.*.center_x - before_x) * graph.*.zoom / dt;
                graph.*.pan_speed_y = -(graph.*.center_y - before_y) * graph.*.zoom / dt;
            }
            graph.*.pan_clock = now;
            rvn_ng_sync(graph, null);
        },
        else => {},
    }
    widget_h.rvn_widget_invalidate_paint(widget);
}

fn rvn_ng_next_stop(zoom: f32, direction: c_int) f32 {
    const count = g_ng_stops.len;
    var i: usize = 0;
    if (direction > 0) {
        while (i < count) : (i += 1) {
            if (g_ng_stops[i] > zoom + 0.001) return g_ng_stops[i];
        }
        return g_ng_stops[count - 1];
    }
    i = count;
    while (i > 0) : (i -= 1) {
        if (g_ng_stops[i - 1] < zoom - 0.001) return g_ng_stops[i - 1];
    }
    return g_ng_stops[0];
}

fn rvn_node_graph_event(widget: [*c]widget_h.rvn_widget_t, event: [*c]const raven.REvent) callconv(.c) c_int {
    const graph: [*c]rvn_node_graph_t = @ptrCast(@alignCast(widget));
    const origin = widget_h.rvn_widget_origin(widget);
    const x = event.*.x - origin.x;
    const y = event.*.y - origin.y;
    var i: u32 = 0;

    rvn_ng_geometry(graph);
    const at = rvn_ng_to_canvas(graph, x, y);
    const mods: u32 = event.*.modifiers;
    switch (event.*.type) {
        raven.R_EVENT_MOUSE_ENTER => {
            graph.*.mouse_in = raven.R_TRUE;
            widget_h.rvn_widget_invalidate_paint(widget);
            return raven.R_FALSE;
        },
        raven.R_EVENT_MOUSE_LEAVE => {
            graph.*.mouse_in = raven.R_FALSE;
            graph.*.hot_node = 0;
            graph.*.hot_pin = 0;
            graph.*.hot_link = 0;
            widget_h.rvn_widget_invalidate_paint(widget);
            return raven.R_FALSE;
        },
        raven.R_EVENT_MOUSE_MOVE => {
            graph.*.mouse_in = raven.R_TRUE;
            if (graph.*.drag != RVN_NG_DRAG_NONE) {
                rvn_ng_drag_to(widget, x, y);
                return raven.R_TRUE;
            }
            rvn_ng_update_hot(widget, x, y);
            return raven.R_FALSE;
        },
        raven.R_EVENT_MOUSE_WHEEL => {
            const amount = event.*.wheel_y;
            if (graph.*.drag != RVN_NG_DRAG_NONE and graph.*.drag != RVN_NG_DRAG_LINK) return raven.R_TRUE;
            if (event.*.wheel_x != 0.0 or (amount != 0.0 and (mods & RVN_MOD_SHIFT) != 0)) {
                const slide: f32 = if (event.*.wheel_x != 0.0) event.*.wheel_x else amount;
                rvn_ng_unpin(graph);
                rvn_ng_set_view(graph, graph.*.center_x - slide * 60.0 / graph.*.zoom, graph.*.center_y, graph.*.zoom, raven.R_TRUE);
                return raven.R_TRUE;
            }
            if (amount != 0.0) {
                var zoom = graph.*.zoom;
                var steps: c_int = @intFromFloat(base.rvn_maxf(1.0, @floor(@abs(amount) + 0.5)));
                while (steps > 0) : (steps -= 1) {
                    zoom = rvn_ng_next_stop(zoom, if (amount > 0.0) 1 else -1);
                }
                rvn_ng_zoom_at(graph, x, y, zoom);
                return raven.R_TRUE;
            }
            return raven.R_FALSE;
        },
        raven.R_EVENT_MOUSE_DOWN => {
            const add: c_int = @intFromBool((mods & (RVN_MOD_CTRL | RVN_MOD_SHIFT)) != 0);
            var node_id: c_int = 0;
            if (graph.*.drag != RVN_NG_DRAG_NONE) return raven.R_TRUE;
            graph.*.press_x = x;
            graph.*.press_y = y;
            graph.*.press_cx = at.x;
            graph.*.press_cy = at.y;
            graph.*.drag_moved = raven.R_FALSE;
            if (event.*.button == raven.R_MOUSE_MIDDLE or (event.*.button == raven.R_MOUSE_LEFT and ((mods & RVN_MOD_ALT) != 0 or graph.*.space_down != 0))) {
                rvn_ng_unpin(graph);
                graph.*.drag = RVN_NG_DRAG_PAN;
                graph.*.pan_from_x = graph.*.center_x;
                graph.*.pan_from_y = graph.*.center_y;
                graph.*.pan_speed_x = 0.0;
                graph.*.pan_speed_y = 0.0;
                graph.*.pan_clock = thread_h.rvn_clock_seconds();
                widget_h.rvn_widget_capture_mouse(widget);
                return raven.R_TRUE;
            }
            if (event.*.button == raven.R_MOUSE_RIGHT) {
                // the menu of a node (selected first), or of the empty canvas (node 0)
                if (graph.*.context_callback == null) return raven.R_FALSE;
                node_id = rvn_ng_node_at(graph, at.x, at.y);
                if (node_id != 0) {
                    const node = rvn_ng_node(graph, node_id);
                    if (node != null and node.*.selected == 0 and rvn_ng_select_only(graph, node_id, 0) != 0) {
                        rvn_ng_notify(widget, graph.*.selection_callback, graph.*.selection_user, node_id);
                        if (common_h.rvn_widget_alive(widget) == 0) return raven.R_TRUE;
                    }
                }
                graph.*.context_callback.?(widget.*.id, node_id, x, y, graph.*.context_user);
                return raven.R_TRUE;
            }
            if (event.*.button != raven.R_MOUSE_LEFT) return raven.R_FALSE;

            const pin = rvn_ng_pin_near(graph, at.x, at.y);
            if (pin != 0 and graph.*.read_only == 0) {
                rvn_ng_begin_wire(widget, pin, at.x, at.y);
                return raven.R_TRUE;
            }
            node_id = rvn_ng_node_at(graph, at.x, at.y);
            if (node_id != 0 and event.*.clicks >= 2 and graph.*.activated_callback != null) {
                // double click: the application opens it (a sub-graph, an asset...)
                rvn_ng_notify(widget, graph.*.activated_callback, graph.*.activated_user, node_id);
                return raven.R_TRUE;
            }
            if (node_id != 0) {
                var node = rvn_ng_node(graph, node_id);
                var changed: c_int = raven.R_FALSE;
                if (add != 0) {
                    node.*.selected = @intFromBool(node.*.selected == 0);
                    changed = raven.R_TRUE;
                } else if (node.*.selected == 0) {
                    changed = rvn_ng_select_only(graph, node_id, 0);
                }
                rvn_ng_raise(graph, node_id);
                widget_h.rvn_widget_invalidate_paint(widget);
                if (changed != 0) rvn_ng_notify(widget, graph.*.selection_callback, graph.*.selection_user, node_id);
                if (common_h.rvn_widget_alive(widget) == 0) return raven.R_TRUE;
                node = rvn_ng_node(graph, node_id);
                if (node != null and node.*.selected != 0 and graph.*.read_only == 0) {
                    i = 0;
                    while (i < graph.*.node_count) : (i += 1) {
                        graph.*.nodes[i].from_x = graph.*.nodes[i].x;
                        graph.*.nodes[i].from_y = graph.*.nodes[i].y;
                    }
                    graph.*.drag = RVN_NG_DRAG_MOVE;
                    graph.*.drag_node = node_id;
                    widget_h.rvn_widget_capture_mouse(widget);
                }
                return raven.R_TRUE;
            }
            const link_id = rvn_ng_link_at(graph, at.x, at.y);
            if (link_id != 0) {
                const link = rvn_ng_link(graph, link_id);
                var changed: c_int = raven.R_TRUE;
                if (add != 0) {
                    link.*.selected = @intFromBool(link.*.selected == 0);
                } else {
                    changed = rvn_ng_select_only(graph, 0, link_id);
                }
                widget_h.rvn_widget_invalidate_paint(widget);
                if (changed != 0) rvn_ng_notify(widget, graph.*.selection_callback, graph.*.selection_user, 0);
                return raven.R_TRUE;
            }
            if (event.*.clicks >= 2) {
                rvn_ng_frame_all(graph, raven.R_TRUE);
                return raven.R_TRUE;
            }
            // the empty canvas: a selection rectangle
            i = 0;
            while (i < graph.*.node_count) : (i += 1) graph.*.nodes[i].from_selected = graph.*.nodes[i].selected;
            graph.*.box = base.rvn_rect(x, y, 0.0, 0.0);
            graph.*.box_add = add;
            graph.*.drag = RVN_NG_DRAG_BOX;
            widget_h.rvn_widget_capture_mouse(widget);
            return raven.R_TRUE;
        },
        raven.R_EVENT_MOUSE_UP => {
            if (graph.*.drag == RVN_NG_DRAG_NONE) return raven.R_FALSE;
            if (graph.*.drag == RVN_NG_DRAG_PAN) {
                if (event.*.button != raven.R_MOUSE_MIDDLE and event.*.button != raven.R_MOUSE_LEFT) return raven.R_TRUE;
            } else if (event.*.button != raven.R_MOUSE_LEFT) {
                return raven.R_TRUE;
            }
            // a click on one of several selected nodes, without moving: it becomes the only one
            if (graph.*.drag == RVN_NG_DRAG_MOVE and graph.*.drag_moved == 0 and (mods & (RVN_MOD_CTRL | RVN_MOD_SHIFT)) == 0) {
                const id = graph.*.drag_node;
                if (rvn_ng_select_only(graph, id, 0) != 0) {
                    rvn_ng_notify(widget, graph.*.selection_callback, graph.*.selection_user, id);
                    if (common_h.rvn_widget_alive(widget) == 0) return raven.R_TRUE;
                }
            }
            rvn_ng_end_drag(widget, raven.R_FALSE);
            if (common_h.rvn_widget_alive(widget) != 0) rvn_ng_update_hot(widget, x, y);
            return raven.R_TRUE;
        },
        raven.R_EVENT_KEY_UP => {
            if (event.*.key == raven.R_KEY_SPACE) graph.*.space_down = raven.R_FALSE;
            return raven.R_FALSE;
        },
        raven.R_EVENT_KEY_DOWN => {
            const step: f32 = if ((mods & RVN_MOD_SHIFT) != 0) 40.0 else 8.0;
            var dx: f32 = 0.0;
            var dy: f32 = 0.0;
            if (event.*.key == raven.R_KEY_ESCAPE) {
                if (graph.*.drag == RVN_NG_DRAG_NONE) return raven.R_FALSE;
                rvn_ng_end_drag(widget, raven.R_TRUE);
                return raven.R_TRUE;
            }
            // the rest is for the graph itself: a key typed in a widget of a node is not for it
            if (event.*.target != widget.*.id) return raven.R_FALSE;
            switch (event.*.key) {
                raven.R_KEY_SPACE => {
                    graph.*.space_down = raven.R_TRUE;
                    return raven.R_TRUE;
                },
                raven.R_KEY_DELETE, raven.R_KEY_BACKSPACE => {
                    if (graph.*.read_only != 0) return raven.R_FALSE;
                    rvn_ng_remove_selected(widget);
                    return raven.R_TRUE;
                },
                raven.R_KEY_HOME, raven.R_KEY_F => {
                    rvn_ng_frame_all(graph, raven.R_TRUE);
                    return raven.R_TRUE;
                },
                raven.R_KEY_A => {
                    if ((mods & RVN_MOD_CTRL) == 0) return raven.R_FALSE;
                    i = 0;
                    while (i < graph.*.node_count) : (i += 1) graph.*.nodes[i].selected = raven.R_TRUE;
                    widget_h.rvn_widget_invalidate_paint(widget);
                    rvn_ng_notify(widget, graph.*.selection_callback, graph.*.selection_user, 0);
                    return raven.R_TRUE;
                },
                raven.R_KEY_LEFT => {
                    dx = -step;
                },
                raven.R_KEY_RIGHT => {
                    dx = step;
                },
                raven.R_KEY_UP => {
                    dy = -step;
                },
                raven.R_KEY_DOWN => {
                    dy = step;
                },
                else => return raven.R_FALSE,
            }
            if (graph.*.read_only != 0 or graph.*.drag != RVN_NG_DRAG_NONE) return raven.R_FALSE;
            {
                // the arrows nudge what is selected
                var any: c_int = raven.R_FALSE;
                i = 0;
                while (i < graph.*.node_count) : (i += 1) {
                    if (graph.*.nodes[i].selected == 0) continue;
                    graph.*.nodes[i].x += dx;
                    graph.*.nodes[i].y += dy;
                    graph.*.nodes[i].from_selected = raven.R_TRUE;
                    any = raven.R_TRUE;
                }
                if (any == 0) return raven.R_FALSE;
                rvn_ng_place_contents(graph);
                widget_h.rvn_widget_invalidate_paint(widget);
                i = 0;
                while (i < graph.*.node_count) : (i +%= 1) {
                    const id = graph.*.nodes[i].id;
                    if (graph.*.nodes[i].selected == 0 or graph.*.nodes[i].from_selected == 0) continue;
                    graph.*.nodes[i].from_selected = raven.R_FALSE;
                    rvn_ng_notify(widget, graph.*.moved_callback, graph.*.moved_user, id);
                    if (common_h.rvn_widget_alive(widget) == 0) return raven.R_TRUE;
                    i = RVN_NG_RESTART;
                }
                widget_h.rvn_widget_fire_action(widget);
                return raven.R_TRUE;
            }
        },
        else => return raven.R_FALSE,
    }
}

// ---------------------------------------------------------------------------
//  XML
// ---------------------------------------------------------------------------

fn rvn_ng_find_node(graph: [*c]const rvn_node_graph_t, name: [*c]const u8) c_int {
    var i: u32 = 0;
    if (name == null or name[0] == 0) return 0;
    while (i < graph.*.node_count) : (i += 1) {
        if (graph.*.nodes[i].name != null and base.rvn_stricmp(graph.*.nodes[i].name, name) == 0) return graph.*.nodes[i].id;
    }
    // a node without a name answers to its title
    i = 0;
    while (i < graph.*.node_count) : (i += 1) {
        if (graph.*.nodes[i].name == null and graph.*.nodes[i].title != null and base.rvn_stricmp(graph.*.nodes[i].title, name) == 0) return graph.*.nodes[i].id;
    }
    return 0;
}

/// `output`: 1 or 0 to look only at the outputs or the inputs, -1 for both.
fn rvn_ng_find_pin(graph: [*c]const rvn_node_graph_t, node: c_int, name: [*c]const u8, output: c_int) c_int {
    var i: u32 = 0;
    if (name == null) return 0;
    while (i < graph.*.pin_count) : (i += 1) {
        const pin: [*c]const rvn_ng_pin_t = &graph.*.pins[i];
        if (pin.*.node != node or (output >= 0 and pin.*.output != output)) continue;
        if (pin.*.name != null and base.rvn_stricmp(pin.*.name, name) == 0) return pin.*.id;
    }
    i = 0;
    while (i < graph.*.pin_count) : (i += 1) {
        const pin: [*c]const rvn_ng_pin_t = &graph.*.pins[i];
        if (pin.*.node != node or (output >= 0 and pin.*.output != output)) continue;
        if (pin.*.name == null and pin.*.label != null and base.rvn_stricmp(pin.*.label, name) == 0) return pin.*.id;
    }
    return 0;
}

/// "node.pin", or "node" alone for its first output (or its first free input).
fn rvn_ng_xml_pin(graph: [*c]rvn_node_graph_t, element: [*c]const xml_h.rvn_xml_node_t, attribute: [*c]const u8, output: c_int) c_int {
    const text = xml_h.rvn_xml_attribute(element, attribute);
    var dot: [*c]const u8 = undefined;
    var name: [96]u8 = undefined;
    var node: c_int = undefined;
    var pin: c_int = 0;
    var i: u32 = 0;
    if (text == null or text[0] == 0) {
        base.rvn_error(raven.R_ERROR_XML, raven.R_SEVERITY_WARNING, "XML line %d: <Link> needs %s=\"node.pin\"", element.*.line, attribute);
        return 0;
    }
    dot = libc.strrchr(text, '.');
    const name_length: c_int = if (dot != null) @intCast(@intFromPtr(dot) - @intFromPtr(text)) else @intCast(libc.strlen(text));
    _ = libc.snprintf(&name, name.len, "%.*s", name_length, text);
    node = rvn_ng_find_node(graph, &name);
    if (node == 0 and dot != null) {
        // (a name with a dot in it, and no pin)
        node = rvn_ng_find_node(graph, text);
        if (node != 0) dot = null;
    }
    if (node == 0) {
        base.rvn_error(raven.R_ERROR_XML, raven.R_SEVERITY_WARNING, "XML line %d: <Link %s=\"%.80s\">: no node of that name before the link", element.*.line, attribute, text);
        return 0;
    }
    if (dot != null) {
        pin = rvn_ng_find_pin(graph, node, dot + 1, output);
    } else {
        while (i < graph.*.pin_count and pin == 0) : (i += 1) {
            const candidate: [*c]const rvn_ng_pin_t = &graph.*.pins[i];
            if (candidate.*.node == node and candidate.*.output == output and (output != 0 or rvn_ng_input_link(graph, candidate.*.id) == null)) pin = candidate.*.id;
        }
    }
    if (pin == 0) {
        const kind: [*c]const u8 = if (output != 0) "output" else "input";
        base.rvn_error(raven.R_ERROR_XML, raven.R_SEVERITY_WARNING, "XML line %d: <Link %s=\"%.80s\">: the node has no such %s", element.*.line, attribute, text, kind);
    }
    return pin;
}

fn rvn_node_graph_xml_child(widget: [*c]widget_h.rvn_widget_t, element: [*c]const xml_h.rvn_xml_node_t) callconv(.c) c_int {
    const graph: [*c]rvn_node_graph_t = @ptrCast(@alignCast(widget));
    var child: [*c]xml_h.rvn_xml_node_t = undefined;
    var text: [*c]const u8 = undefined;
    var color: base.rvn_color_t = undefined;
    var flag: c_int = undefined;

    if (base.rvn_stricmp(element.*.name, "Type") == 0) {
        const type_index = rvn_ng_type(graph, xml_h.rvn_xml_attribute(element, "Name"));
        text = xml_h.rvn_xml_attribute(element, "Color");
        if (type_index >= 0 and text != null and widget_h.rvn_parse_color(text, &color) != 0) {
            const ty: [*c]rvn_ng_type_t = &graph.*.types[@intCast(type_index)];
            ty.*.color = color | 0xFF000000;
            ty.*.has_color = raven.R_TRUE;
        }
        return raven.R_TRUE;
    }
    if (base.rvn_stricmp(element.*.name, "Link") == 0) {
        const from = rvn_ng_xml_pin(graph, element, "From", raven.R_TRUE);
        const to = if (from != 0) rvn_ng_xml_pin(graph, element, "To", raven.R_FALSE) else 0;
        if (from != 0 and to != 0) {
            if (rvn_ng_can_link(rvn_ng_pin(graph, from), rvn_ng_pin(graph, to)) == 0) {
                base.rvn_error(raven.R_ERROR_XML, raven.R_SEVERITY_WARNING, "XML line %d: <Link>: these two pins cannot be linked (same node, or different types)", element.*.line);
            } else {
                _ = rvn_ng_add_link(graph, from, to, raven.R_FALSE);
            }
        }
        return raven.R_TRUE;
    }
    if (base.rvn_stricmp(element.*.name, "Node") == 0) {
        var content: [*c]widget_h.rvn_widget_t = null;
        var box: [*c]widget_h.rvn_widget_t = null;
        var x: f32 = 0.0;
        var y: f32 = 0.0;
        text = xml_h.rvn_xml_attribute(element, "X");
        if (text != null) _ = widget_h.rvn_parse_float(text, &x);
        text = xml_h.rvn_xml_attribute(element, "Y");
        if (text != null) _ = widget_h.rvn_parse_float(text, &y);
        text = xml_h.rvn_xml_attribute(element, "Title");
        const name_attr = xml_h.rvn_xml_attribute(element, "Name");
        const title: [*c]const u8 = if (text != null) text else if (name_attr != null) name_attr else "";
        const id = Rnode_graph_add_node(widget.*.id, title, x, y);
        var node = rvn_ng_node(graph, id);
        if (node == null) return raven.R_TRUE;
        text = xml_h.rvn_xml_attribute(element, "Name");
        if (text != null) node.*.name = base.rvn_strdup(text);
        text = xml_h.rvn_xml_attribute(element, "Color");
        if (text != null and widget_h.rvn_parse_color(text, &color) != 0) {
            node.*.color = color | 0xFF000000;
            node.*.has_color = raven.R_TRUE;
        }
        text = xml_h.rvn_xml_attribute(element, "Selected");
        if (text != null and widget_h.rvn_parse_bool(text, &flag) != 0) node.*.selected = flag;
        child = element.*.first_child;
        while (child != null) : (child = child.*.next) {
            const output = base.rvn_stricmp(child.*.name, "Output") == 0;
            if (output or base.rvn_stricmp(child.*.name, "Input") == 0) {
                var label: [*c]const u8 = xml_h.rvn_xml_attribute(child, "Label");
                const name = xml_h.rvn_xml_attribute(child, "Name");
                if (label == null) {
                    label = if (child.*.text != null and child.*.text[0] != 0) child.*.text else if (name != null) name else "";
                }
                const pin_id: c_int = if (output)
                    Rnode_graph_add_output(widget.*.id, id, label, xml_h.rvn_xml_attribute(child, "Type"))
                else
                    Rnode_graph_add_input(widget.*.id, id, label, xml_h.rvn_xml_attribute(child, "Type"));
                if (name != null and rvn_ng_pin(graph, pin_id) != null) rvn_ng_pin(graph, pin_id).*.name = base.rvn_strdup(name);
            } else {
                // anything else is a widget for the inside of the node; several are stacked
                // (xml_h names its widget type with a placeholder: it is the same struct as widget_h.rvn_widget_t)
                const built: [*c]widget_h.rvn_widget_t = @ptrCast(@alignCast(xml_h.rvn_xml_build_node(child)));
                if (built == null) continue;
                if (content == null) {
                    content = built;
                } else {
                    if (box == null) {
                        box = widget_h.rvn_widget_create(raven.R_WIDGET_VBOX);
                        const spaced: [*c]common_h.rvn_spaced_panel_t = @ptrCast(@alignCast(box));
                        spaced.*.spacing = 6.0;
                        widget_h.rvn_widget_add_child(box, content, -1);
                        content = box;
                    }
                    widget_h.rvn_widget_add_child(box, built, -1);
                }
            }
        }
        if (content != null) {
            widget_h.rvn_widget_add_child(widget, content, -1);
            // (adding a child may have moved the nodes in memory)
            node = rvn_ng_node(graph, id);
            if (node != null) node.*.content = content;
        }
        rvn_ng_changed(graph);
        return raven.R_TRUE;
    }
    return raven.R_FALSE;
}

fn rvn_node_graph_set_attribute(widget: [*c]widget_h.rvn_widget_t, name: [*c]const u8, value: [*c]const u8) callconv(.c) c_int {
    const graph: [*c]rvn_node_graph_t = @ptrCast(@alignCast(widget));
    var number: f32 = undefined;
    var x: f32 = undefined;
    var y: f32 = undefined;
    var flag: c_int = undefined;

    if (base.rvn_stricmp(name, "Zoom") == 0) {
        if (widget_h.rvn_parse_float(value, &number) == 0 or number <= 0.0) return raven.R_FALSE;
        graph.*.zoom = base.rvn_clampf(number, RVN_NG_ZOOM_MIN, RVN_NG_ZOOM_MAX);
        draw_h.rvn_spring_set(&graph.*.shown_zoom, graph.*.zoom);
    } else if (base.rvn_stricmp(name, "CenterX") == 0 or base.rvn_stricmp(name, "CenterY") == 0) {
        if (widget_h.rvn_parse_float(value, &number) == 0) return raven.R_FALSE;
        rvn_ng_target(graph, &x, &y);
        if (base.rvn_stricmp(name, "CenterX") == 0) {
            x = number;
        } else {
            y = number;
        }
        rvn_ng_set_view(graph, x, y, graph.*.zoom, raven.R_FALSE);
    } else if (base.rvn_stricmp(name, "Grid") == 0) {
        if (widget_h.rvn_parse_bool(value, &flag) == 0) return raven.R_FALSE;
        graph.*.grid_hidden = @intFromBool(flag == 0);
    } else if (base.rvn_stricmp(name, "Flow") == 0) {
        if (base.rvn_stricmp(value, "Auto") == 0) {
            graph.*.flow_mode = RVN_NG_FLOW_AUTO;
        } else if (widget_h.rvn_parse_bool(value, &flag) != 0) {
            graph.*.flow_mode = if (flag != 0) RVN_NG_FLOW_ALWAYS else RVN_NG_FLOW_NEVER;
        } else {
            return raven.R_FALSE;
        }
    } else if (base.rvn_stricmp(name, "ReadOnly") == 0) {
        if (widget_h.rvn_parse_bool(value, &flag) == 0) return raven.R_FALSE;
        graph.*.read_only = flag;
    } else if (base.rvn_stricmp(name, "FrameAll") == 0) {
        if (widget_h.rvn_parse_bool(value, &flag) == 0) return raven.R_FALSE;
        if (flag != 0) {
            rvn_ng_frame_all(graph, raven.R_FALSE);
        } else {
            graph.*.frame_pending = raven.R_FALSE;
        }
    } else {
        return raven.R_FALSE;
    }
    rvn_ng_sync(graph, null);
    widget_h.rvn_widget_invalidate_paint(widget);
    return raven.R_TRUE;
}

export const rvn_class_node_graph: widget_h.rvn_widget_class_t = .{
    .type = raven.R_WIDGET_NODE_GRAPH,
    .name = "NodeGraph",
    .size = @sizeOf(rvn_node_graph_t),
    .flags = widget_h.RVN_CF_NO_CHILDREN | widget_h.RVN_CF_FOCUSABLE | widget_h.RVN_CF_CLIP | widget_h.RVN_CF_SURFACE | widget_h.RVN_CF_OWN_CHILDREN | widget_h.RVN_CF_UI_PAINT | widget_h.RVN_CF_NO_MIRROR,
    .init = rvn_node_graph_init,
    .destroy = rvn_node_graph_destroy,
    .measure = rvn_node_graph_measure,
    .arrange = rvn_node_graph_arrange,
    .paint = rvn_node_graph_paint,
    .paint_overlay = rvn_node_graph_paint_overlay,
    .event = rvn_node_graph_event,
    .set_attribute = rvn_node_graph_set_attribute,
    .child_active = null,
    .child_at = rvn_node_graph_child_at,
    .children_changed = rvn_node_graph_children_changed,
    .xml_child = rvn_node_graph_xml_child,
    .popup_closed = null,
    .window_drag_at = null,
};

// ---------------------------------------------------------------------------
//  Public API
// ---------------------------------------------------------------------------

/// The graph behind a widget id, or NULL (the check reports the error).
fn nodeGraphCheck(id: raven.Rid, function: [*c]const u8) [*c]rvn_node_graph_t {
    return @ptrCast(@alignCast(widget_h.rvn_widget_check(id, raven.R_WIDGET_NODE_GRAPH, function)));
}

/// A node of a graph for a public function: reports the error itself.
fn rvn_ng_node_checked(graph: [*c]rvn_node_graph_t, id: c_int, function: [*c]const u8) [*c]rvn_ng_node_t {
    const node = rvn_ng_node(graph, id);
    if (node == null) base.rvn_error(raven.R_ERROR_INVALID_VALUE, raven.R_SEVERITY_ERROR, "%s: the graph has no node %d", function, id);
    return node;
}

fn rvn_ng_pin_checked(graph: [*c]rvn_node_graph_t, id: c_int, function: [*c]const u8) [*c]rvn_ng_pin_t {
    const pin = rvn_ng_pin(graph, id);
    if (pin == null) base.rvn_error(raven.R_ERROR_INVALID_VALUE, raven.R_SEVERITY_ERROR, "%s: the graph has no pin %d", function, id);
    return pin;
}

export fn Rnode_graph_create() raven.Rid {
    if (ctx_h.rvn_api_check("Rnode_graph_create") == 0) return raven.R_INVALID_ID;
    const widget = widget_h.rvn_widget_create(raven.R_WIDGET_NODE_GRAPH);
    return if (widget != null) widget.*.id else raven.R_INVALID_ID;
}

// ---- nodes ----

export fn Rnode_graph_add_node(id: raven.Rid, title: [*c]const u8, x: f32, y: f32) c_int {
    const graph = nodeGraphCheck(id, "Rnode_graph_add_node");
    if (graph == null) return 0;
    base.RVN_ARRAY_RESERVE(&graph.*.nodes, &graph.*.node_cap, graph.*.node_count + 1);
    const index = graph.*.node_count;
    graph.*.node_count += 1;
    const node: [*c]rvn_ng_node_t = &graph.*.nodes[index];
    node.* = std.mem.zeroes(rvn_ng_node_t);
    node.*.id = graph.*.next_id;
    graph.*.next_id += 1;
    const title_text: [*c]const u8 = if (title != null) title else "";
    node.*.title = base.rvn_strdup(title_text);
    node.*.x = x;
    node.*.y = y;
    // what is there when the graph first shows does not pop in
    if (graph.*.painted == 0) draw_h.rvn_spring_set(&node.*.appear, 1.0);
    rvn_ng_changed(graph);
    return node.*.id;
}

export fn Rnode_graph_remove_node(id: raven.Rid, node: c_int) void {
    const graph = nodeGraphCheck(id, "Rnode_graph_remove_node");
    if (graph == null) return;
    rvn_ng_remove_node(graph, node);
}

export fn Rnode_graph_clear(id: raven.Rid) void {
    const graph = nodeGraphCheck(id, "Rnode_graph_clear");
    if (graph == null) return;
    rvn_ng_clear(graph);
    rvn_ng_changed(graph);
}

export fn Rnode_graph_get_node_count(id: raven.Rid) c_int {
    const graph = nodeGraphCheck(id, "Rnode_graph_get_node_count");
    if (graph == null) return 0;
    return @intCast(graph.*.node_count);
}

export fn Rnode_graph_get_node(id: raven.Rid, index: c_int) c_int {
    var i: u32 = 0;
    var best: u32 = 0;
    var found: c_int = 0;
    const graph = nodeGraphCheck(id, "Rnode_graph_get_node");
    if (graph == null) return 0;
    if (index < 0 or @as(u32, @intCast(index)) >= graph.*.node_count) return 0;
    // in the order they were made, whatever is on top of what now
    var rank: c_int = 0;
    while (rank <= index) : (rank += 1) {
        const after = found;
        found = 0;
        i = 0;
        while (i < graph.*.node_count) : (i += 1) {
            if (graph.*.nodes[i].id > after and (found == 0 or graph.*.nodes[i].id < @as(c_int, @bitCast(best)))) {
                best = @bitCast(graph.*.nodes[i].id);
                found = graph.*.nodes[i].id;
            }
        }
    }
    return found;
}

export fn Rnode_graph_set_node_title(id: raven.Rid, node_id: c_int, title: [*c]const u8) void {
    const graph = nodeGraphCheck(id, "Rnode_graph_set_node_title");
    if (graph == null) return;
    const node = rvn_ng_node_checked(graph, node_id, "Rnode_graph_set_node_title");
    if (node == null) return;
    base.rvn_free(node.*.title);
    const title_text: [*c]const u8 = if (title != null) title else "";
    node.*.title = base.rvn_strdup(title_text);
    rvn_ng_changed(graph);
}

export fn Rnode_graph_get_node_title(id: raven.Rid, node_id: c_int) [*c]const u8 {
    const graph = nodeGraphCheck(id, "Rnode_graph_get_node_title");
    if (graph == null) return "";
    const node = rvn_ng_node_checked(graph, node_id, "Rnode_graph_get_node_title");
    return if (node != null and node.*.title != null) node.*.title else "";
}

export fn Rnode_graph_set_node_position(id: raven.Rid, node_id: c_int, x: f32, y: f32) void {
    const graph = nodeGraphCheck(id, "Rnode_graph_set_node_position");
    if (graph == null) return;
    const node = rvn_ng_node_checked(graph, node_id, "Rnode_graph_set_node_position");
    if (node == null) return;
    node.*.x = x;
    node.*.y = y;
    rvn_ng_place_contents(graph);
    widget_h.rvn_widget_invalidate_paint(&graph.*.base);
}

export fn Rnode_graph_get_node_position(id: raven.Rid, node_id: c_int, x: [*c]f32, y: [*c]f32) void {
    const graph = nodeGraphCheck(id, "Rnode_graph_get_node_position");
    const node = if (graph != null) rvn_ng_node_checked(graph, node_id, "Rnode_graph_get_node_position") else null;
    if (x != null) x.* = if (node != null) node.*.x else 0.0;
    if (y != null) y.* = if (node != null) node.*.y else 0.0;
}

export fn Rnode_graph_get_node_size(id: raven.Rid, node_id: c_int, width: [*c]f32, height: [*c]f32) void {
    const graph = nodeGraphCheck(id, "Rnode_graph_get_node_size");
    if (graph != null) rvn_ng_geometry(graph);
    const node = if (graph != null) rvn_ng_node_checked(graph, node_id, "Rnode_graph_get_node_size") else null;
    if (width != null) width.* = if (node != null) node.*.w else 0.0;
    if (height != null) height.* = if (node != null) node.*.h else 0.0;
}

export fn Rnode_graph_set_node_color(id: raven.Rid, node_id: c_int, r: f32, g: f32, b: f32) void {
    const graph = nodeGraphCheck(id, "Rnode_graph_set_node_color");
    if (graph == null) return;
    const node = rvn_ng_node_checked(graph, node_id, "Rnode_graph_set_node_color");
    if (node == null) return;
    node.*.color = base.rvn_rgba(r, g, b, 1.0);
    node.*.has_color = raven.R_TRUE;
    widget_h.rvn_widget_invalidate_paint(&graph.*.base);
}

export fn Rnode_graph_set_node_content(id: raven.Rid, node_id: c_int, content_id: raven.Rid) void {
    const graph = nodeGraphCheck(id, "Rnode_graph_set_node_content");
    if (graph == null) return;
    var node = rvn_ng_node_checked(graph, node_id, "Rnode_graph_set_node_content");
    if (node == null) return;
    var content: [*c]widget_h.rvn_widget_t = null;
    if (content_id != raven.R_INVALID_ID) {
        content = widget_h.rvn_widget_check(content_id, @as(raven.RWidgetType, 0), "Rnode_graph_set_node_content");
        if (content == null) return;
        if (content == node.*.content) return;
        if (content == &graph.*.base or widget_h.rvn_widget_is_inside(&graph.*.base, content) != 0 or (content.*.flags & widget_h.RVN_WF_POPUP) != 0) {
            base.rvn_error(raven.R_ERROR_INVALID_VALUE, raven.R_SEVERITY_ERROR, "Rnode_graph_set_node_content: this widget cannot go inside a node of this graph");
            return;
        }
    }
    const old = node.*.content;
    node.*.content = null;
    if (old != null) widget_h.rvn_widget_destroy(old);
    if (content != null) {
        if (content.*.parent != null) widget_h.rvn_widget_detach(content);
        widget_h.rvn_widget_add_child(&graph.*.base, content, -1);
        node = rvn_ng_node(graph, node_id);
        if (node != null) node.*.content = content;
    }
    rvn_ng_changed(graph);
}

export fn Rnode_graph_get_node_content(id: raven.Rid, node_id: c_int) raven.Rid {
    const graph = nodeGraphCheck(id, "Rnode_graph_get_node_content");
    if (graph == null) return raven.R_INVALID_ID;
    const node = rvn_ng_node_checked(graph, node_id, "Rnode_graph_get_node_content");
    return if (node != null and node.*.content != null) node.*.content.*.id else raven.R_INVALID_ID;
}

export fn Rnode_graph_set_node_name(id: raven.Rid, node_id: c_int, name: [*c]const u8) void {
    const graph = nodeGraphCheck(id, "Rnode_graph_set_node_name");
    if (graph == null) return;
    const node = rvn_ng_node_checked(graph, node_id, "Rnode_graph_set_node_name");
    if (node == null) return;
    base.rvn_free(node.*.name);
    node.*.name = if (name != null and name[0] != 0) base.rvn_strdup(name) else null;
}

export fn Rnode_graph_get_node_name(id: raven.Rid, node_id: c_int) [*c]const u8 {
    const graph = nodeGraphCheck(id, "Rnode_graph_get_node_name");
    if (graph == null) return "";
    const node = rvn_ng_node_checked(graph, node_id, "Rnode_graph_get_node_name");
    return if (node != null and node.*.name != null) node.*.name else "";
}

export fn Rnode_graph_find_node(id: raven.Rid, name: [*c]const u8) c_int {
    const graph = nodeGraphCheck(id, "Rnode_graph_find_node");
    if (graph == null) return 0;
    return rvn_ng_find_node(graph, name);
}

export fn Rnode_graph_set_node_user_data(id: raven.Rid, node_id: c_int, user_data: ?*anyopaque) void {
    const graph = nodeGraphCheck(id, "Rnode_graph_set_node_user_data");
    if (graph == null) return;
    const node = rvn_ng_node_checked(graph, node_id, "Rnode_graph_set_node_user_data");
    if (node != null) node.*.user = user_data;
}

export fn Rnode_graph_get_node_user_data(id: raven.Rid, node_id: c_int) ?*anyopaque {
    const graph = nodeGraphCheck(id, "Rnode_graph_get_node_user_data");
    if (graph == null) return null;
    const node = rvn_ng_node_checked(graph, node_id, "Rnode_graph_get_node_user_data");
    return if (node != null) node.*.user else null;
}

// ---- pins ----

fn rvn_ng_add_pin(id: raven.Rid, node_id: c_int, label: [*c]const u8, @"type": [*c]const u8, output: c_int, function: [*c]const u8) c_int {
    const graph = nodeGraphCheck(id, function);
    if (graph == null or rvn_ng_node_checked(graph, node_id, function) == null) return 0;
    base.RVN_ARRAY_RESERVE(&graph.*.pins, &graph.*.pin_cap, graph.*.pin_count + 1);
    const index = graph.*.pin_count;
    graph.*.pin_count += 1;
    const pin: [*c]rvn_ng_pin_t = &graph.*.pins[index];
    pin.* = std.mem.zeroes(rvn_ng_pin_t);
    pin.*.id = graph.*.next_id;
    graph.*.next_id += 1;
    pin.*.node = node_id;
    pin.*.output = output;
    const label_text: [*c]const u8 = if (label != null) label else "";
    pin.*.label = base.rvn_strdup(label_text);
    pin.*.type = rvn_ng_type(graph, @"type");
    rvn_ng_changed(graph);
    return pin.*.id;
}

export fn Rnode_graph_add_input(id: raven.Rid, node: c_int, label: [*c]const u8, @"type": [*c]const u8) c_int {
    return rvn_ng_add_pin(id, node, label, @"type", raven.R_FALSE, "Rnode_graph_add_input");
}

export fn Rnode_graph_add_output(id: raven.Rid, node: c_int, label: [*c]const u8, @"type": [*c]const u8) c_int {
    return rvn_ng_add_pin(id, node, label, @"type", raven.R_TRUE, "Rnode_graph_add_output");
}

export fn Rnode_graph_remove_pin(id: raven.Rid, pin_id: c_int) void {
    const graph = nodeGraphCheck(id, "Rnode_graph_remove_pin");
    if (graph == null) return;
    var i: u32 = 0;
    while (i < graph.*.pin_count) : (i += 1) {
        if (graph.*.pins[i].id != pin_id) continue;
        if (graph.*.drag == RVN_NG_DRAG_LINK and graph.*.wire_pin == pin_id) {
            graph.*.drag = RVN_NG_DRAG_NONE;
            widget_h.rvn_widget_release_mouse(&graph.*.base);
        }
        rvn_ng_remove_pin_at(graph, i);
        rvn_ng_changed(graph);
        return;
    }
}

export fn Rnode_graph_get_pin_node(id: raven.Rid, pin_id: c_int) c_int {
    const graph = nodeGraphCheck(id, "Rnode_graph_get_pin_node");
    if (graph == null) return 0;
    const pin = rvn_ng_pin_checked(graph, pin_id, "Rnode_graph_get_pin_node");
    return if (pin != null) pin.*.node else 0;
}

export fn Rnode_graph_is_pin_output(id: raven.Rid, pin_id: c_int) c_int {
    const graph = nodeGraphCheck(id, "Rnode_graph_is_pin_output");
    if (graph == null) return raven.R_FALSE;
    const pin = rvn_ng_pin_checked(graph, pin_id, "Rnode_graph_is_pin_output");
    return if (pin != null) pin.*.output else raven.R_FALSE;
}

export fn Rnode_graph_get_pin_label(id: raven.Rid, pin_id: c_int) [*c]const u8 {
    const graph = nodeGraphCheck(id, "Rnode_graph_get_pin_label");
    if (graph == null) return "";
    const pin = rvn_ng_pin_checked(graph, pin_id, "Rnode_graph_get_pin_label");
    return if (pin != null and pin.*.label != null) pin.*.label else "";
}

export fn Rnode_graph_get_pin_type(id: raven.Rid, pin_id: c_int) [*c]const u8 {
    const graph = nodeGraphCheck(id, "Rnode_graph_get_pin_type");
    if (graph == null) return "";
    const pin = rvn_ng_pin_checked(graph, pin_id, "Rnode_graph_get_pin_type");
    return if (pin != null and pin.*.type >= 0) graph.*.types[@intCast(pin.*.type)].name else "";
}

export fn Rnode_graph_get_pin_position(id: raven.Rid, pin_id: c_int, x: [*c]f32, y: [*c]f32) void {
    const graph = nodeGraphCheck(id, "Rnode_graph_get_pin_position");
    var at = base.rvn_vec2(0.0, 0.0);
    if (graph != null) rvn_ng_geometry(graph);
    const pin = if (graph != null) rvn_ng_pin_checked(graph, pin_id, "Rnode_graph_get_pin_position") else null;
    if (pin != null) at = rvn_ng_pin_at_canvas(graph, pin);
    if (x != null) x.* = at.x;
    if (y != null) y.* = at.y;
}

export fn Rnode_graph_set_pin_name(id: raven.Rid, pin_id: c_int, name: [*c]const u8) void {
    const graph = nodeGraphCheck(id, "Rnode_graph_set_pin_name");
    if (graph == null) return;
    const pin = rvn_ng_pin_checked(graph, pin_id, "Rnode_graph_set_pin_name");
    if (pin == null) return;
    base.rvn_free(pin.*.name);
    pin.*.name = if (name != null and name[0] != 0) base.rvn_strdup(name) else null;
}

export fn Rnode_graph_find_pin(id: raven.Rid, node: c_int, name: [*c]const u8) c_int {
    const graph = nodeGraphCheck(id, "Rnode_graph_find_pin");
    if (graph == null) return 0;
    return rvn_ng_find_pin(graph, node, name, -1);
}

fn rvn_ng_nth_pin(id: raven.Rid, node: c_int, index: c_int, output: c_int, function: [*c]const u8) c_int {
    const graph = nodeGraphCheck(id, function);
    var i: u32 = 0;
    var remaining: c_int = index;
    if (graph == null or index < 0) return 0;
    while (i < graph.*.pin_count) : (i += 1) {
        if (graph.*.pins[i].node != node or graph.*.pins[i].output != output) continue;
        if (remaining == 0) return graph.*.pins[i].id;
        remaining -= 1;
    }
    return 0;
}

export fn Rnode_graph_get_input(id: raven.Rid, node: c_int, index: c_int) c_int {
    return rvn_ng_nth_pin(id, node, index, raven.R_FALSE, "Rnode_graph_get_input");
}

export fn Rnode_graph_get_output(id: raven.Rid, node: c_int, index: c_int) c_int {
    return rvn_ng_nth_pin(id, node, index, raven.R_TRUE, "Rnode_graph_get_output");
}

export fn Rnode_graph_set_type_color(id: raven.Rid, type_name: [*c]const u8, r: f32, g: f32, b: f32) void {
    const graph = nodeGraphCheck(id, "Rnode_graph_set_type_color");
    if (graph == null) return;
    const type_index = rvn_ng_type(graph, type_name);
    if (type_index < 0) {
        base.rvn_error(raven.R_ERROR_INVALID_VALUE, raven.R_SEVERITY_ERROR, "Rnode_graph_set_type_color: a type needs a name");
        return;
    }
    const ty: [*c]rvn_ng_type_t = &graph.*.types[@intCast(type_index)];
    ty.*.color = base.rvn_rgba(r, g, b, 1.0);
    ty.*.has_color = raven.R_TRUE;
    widget_h.rvn_widget_invalidate_paint(&graph.*.base);
}

// ---- links ----

export fn Rnode_graph_connect(id: raven.Rid, output_pin: c_int, input_pin: c_int) c_int {
    const graph = nodeGraphCheck(id, "Rnode_graph_connect");
    if (graph == null) return 0;
    const from = rvn_ng_pin_checked(graph, output_pin, "Rnode_graph_connect");
    const to = if (from != null) rvn_ng_pin_checked(graph, input_pin, "Rnode_graph_connect") else null;
    if (from == null or to == null) return 0;
    if (from.*.output == 0 or to.*.output != 0 or rvn_ng_can_link(from, to) == 0) return 0;
    return rvn_ng_add_link(graph, output_pin, input_pin, raven.R_TRUE);
}

export fn Rnode_graph_disconnect(id: raven.Rid, link: c_int) void {
    const graph = nodeGraphCheck(id, "Rnode_graph_disconnect");
    if (graph == null) return;
    rvn_ng_remove_link(graph, link);
}

export fn Rnode_graph_get_link_count(id: raven.Rid) c_int {
    const graph = nodeGraphCheck(id, "Rnode_graph_get_link_count");
    if (graph == null) return 0;
    return @intCast(graph.*.link_count);
}

export fn Rnode_graph_get_link(id: raven.Rid, index: c_int) c_int {
    const graph = nodeGraphCheck(id, "Rnode_graph_get_link");
    if (graph == null) return 0;
    if (index >= 0 and @as(u32, @intCast(index)) < graph.*.link_count) return graph.*.links[@intCast(index)].id;
    return 0;
}

export fn Rnode_graph_get_link_output(id: raven.Rid, link_id: c_int) c_int {
    const graph = nodeGraphCheck(id, "Rnode_graph_get_link_output");
    if (graph == null) return 0;
    const link = rvn_ng_link(graph, link_id);
    return if (link != null) link.*.from else 0;
}

export fn Rnode_graph_get_link_input(id: raven.Rid, link_id: c_int) c_int {
    const graph = nodeGraphCheck(id, "Rnode_graph_get_link_input");
    if (graph == null) return 0;
    const link = rvn_ng_link(graph, link_id);
    return if (link != null) link.*.to else 0;
}

export fn Rnode_graph_get_input_link(id: raven.Rid, input_pin: c_int) c_int {
    const graph = nodeGraphCheck(id, "Rnode_graph_get_input_link");
    if (graph == null) return 0;
    const link = rvn_ng_input_link(graph, input_pin);
    return if (link != null) link.*.id else 0;
}

// ---- view and selection ----

export fn Rnode_graph_set_view(id: raven.Rid, center_x: f32, center_y: f32, zoom: f32) void {
    const graph = nodeGraphCheck(id, "Rnode_graph_set_view");
    if (graph == null) return;
    if (!(zoom > 0.0)) {
        base.rvn_error(raven.R_ERROR_INVALID_VALUE, raven.R_SEVERITY_ERROR, "Rnode_graph_set_view: the zoom must be positive");
        return;
    }
    graph.*.frame_pending = raven.R_FALSE;
    rvn_ng_set_view(graph, center_x, center_y, zoom, raven.R_FALSE);
}

export fn Rnode_graph_get_view(id: raven.Rid, center_x: [*c]f32, center_y: [*c]f32, zoom: [*c]f32) void {
    const graph = nodeGraphCheck(id, "Rnode_graph_get_view");
    var x: f32 = 0.0;
    var y: f32 = 0.0;
    if (graph != null) rvn_ng_target(graph, &x, &y);
    if (center_x != null) center_x.* = x;
    if (center_y != null) center_y.* = y;
    if (zoom != null) zoom.* = if (graph != null) graph.*.zoom else 1.0;
}

export fn Rnode_graph_to_canvas(id: raven.Rid, x: f32, y: f32, canvas_x: [*c]f32, canvas_y: [*c]f32) void {
    const graph = nodeGraphCheck(id, "Rnode_graph_to_canvas");
    const at = if (graph != null) rvn_ng_to_canvas(graph, x, y) else base.rvn_vec2(0.0, 0.0);
    if (canvas_x != null) canvas_x.* = at.x;
    if (canvas_y != null) canvas_y.* = at.y;
}

export fn Rnode_graph_from_canvas(id: raven.Rid, canvas_x: f32, canvas_y: f32, x: [*c]f32, y: [*c]f32) void {
    const graph = nodeGraphCheck(id, "Rnode_graph_from_canvas");
    if (x != null) x.* = if (graph != null) graph.*.pan_x + canvas_x * graph.*.draw_zoom else 0.0;
    if (y != null) y.* = if (graph != null) graph.*.pan_y + canvas_y * graph.*.draw_zoom else 0.0;
}

export fn Rnode_graph_frame_all(id: raven.Rid) void {
    const graph = nodeGraphCheck(id, "Rnode_graph_frame_all");
    if (graph == null) return;
    rvn_ng_frame_all(graph, raven.R_TRUE);
}

export fn Rnode_graph_set_grid_visible(id: raven.Rid, visible: c_int) void {
    const graph = nodeGraphCheck(id, "Rnode_graph_set_grid_visible");
    if (graph == null) return;
    graph.*.grid_hidden = @intFromBool(visible == 0);
    widget_h.rvn_widget_invalidate_paint(&graph.*.base);
}

export fn Rnode_graph_set_flow_visible(id: raven.Rid, visible: c_int) void {
    const graph = nodeGraphCheck(id, "Rnode_graph_set_flow_visible");
    if (graph == null) return;
    graph.*.flow_mode = if (visible != 0) RVN_NG_FLOW_ALWAYS else RVN_NG_FLOW_NEVER;
    widget_h.rvn_widget_invalidate_paint(&graph.*.base);
}

export fn Rnode_graph_set_read_only(id: raven.Rid, read_only: c_int) void {
    const graph = nodeGraphCheck(id, "Rnode_graph_set_read_only");
    if (graph == null) return;
    graph.*.read_only = @intFromBool(read_only != 0);
    if (graph.*.read_only != 0 and (graph.*.drag == RVN_NG_DRAG_MOVE or graph.*.drag == RVN_NG_DRAG_LINK)) rvn_ng_end_drag(&graph.*.base, raven.R_TRUE);
}

export fn Rnode_graph_select_node(id: raven.Rid, node_id: c_int, add: c_int) void {
    const graph = nodeGraphCheck(id, "Rnode_graph_select_node");
    if (graph == null) return;
    const node = rvn_ng_node_checked(graph, node_id, "Rnode_graph_select_node");
    if (node == null) return;
    if (add == 0) _ = rvn_ng_select_only(graph, node_id, 0);
    node.*.selected = raven.R_TRUE;
    widget_h.rvn_widget_invalidate_paint(&graph.*.base);
}

export fn Rnode_graph_clear_selection(id: raven.Rid) void {
    const graph = nodeGraphCheck(id, "Rnode_graph_clear_selection");
    if (graph == null) return;
    _ = rvn_ng_select_only(graph, 0, 0);
}

export fn Rnode_graph_is_node_selected(id: raven.Rid, node_id: c_int) c_int {
    const graph = nodeGraphCheck(id, "Rnode_graph_is_node_selected");
    if (graph == null) return raven.R_FALSE;
    const node = rvn_ng_node(graph, node_id);
    return if (node != null) node.*.selected else raven.R_FALSE;
}

export fn Rnode_graph_get_selection_count(id: raven.Rid) c_int {
    var i: u32 = 0;
    var count: c_int = 0;
    const graph = nodeGraphCheck(id, "Rnode_graph_get_selection_count");
    if (graph == null) return 0;
    while (i < graph.*.node_count) : (i += 1) count += if (graph.*.nodes[i].selected != 0) @as(c_int, 1) else @as(c_int, 0);
    return count;
}

export fn Rnode_graph_get_selected_node(id: raven.Rid, index: c_int) c_int {
    var i: u32 = 0;
    var remaining: c_int = index;
    const graph = nodeGraphCheck(id, "Rnode_graph_get_selected_node");
    if (graph == null) return 0;
    if (index < 0) return 0;
    while (i < graph.*.node_count) : (i += 1) {
        if (graph.*.nodes[i].selected != 0) {
            if (remaining == 0) return graph.*.nodes[i].id;
            remaining -= 1;
        }
    }
    return 0;
}

// ---- callbacks ----

export fn Rnode_graph_set_connect_callback(id: raven.Rid, callback: raven.RNodeGraphConnectCallback, user_data: ?*anyopaque) void {
    const graph = nodeGraphCheck(id, "Rnode_graph_set_connect_callback");
    if (graph == null) return;
    graph.*.connect_callback = callback;
    graph.*.connect_user = user_data;
}

export fn Rnode_graph_set_linked_callback(id: raven.Rid, callback: raven.RNodeGraphItemCallback, user_data: ?*anyopaque) void {
    const graph = nodeGraphCheck(id, "Rnode_graph_set_linked_callback");
    if (graph == null) return;
    graph.*.linked_callback = callback;
    graph.*.linked_user = user_data;
}

export fn Rnode_graph_set_unlinked_callback(id: raven.Rid, callback: raven.RNodeGraphItemCallback, user_data: ?*anyopaque) void {
    const graph = nodeGraphCheck(id, "Rnode_graph_set_unlinked_callback");
    if (graph == null) return;
    graph.*.unlinked_callback = callback;
    graph.*.unlinked_user = user_data;
}

export fn Rnode_graph_set_moved_callback(id: raven.Rid, callback: raven.RNodeGraphItemCallback, user_data: ?*anyopaque) void {
    const graph = nodeGraphCheck(id, "Rnode_graph_set_moved_callback");
    if (graph == null) return;
    graph.*.moved_callback = callback;
    graph.*.moved_user = user_data;
}

export fn Rnode_graph_set_selection_callback(id: raven.Rid, callback: raven.RNodeGraphItemCallback, user_data: ?*anyopaque) void {
    const graph = nodeGraphCheck(id, "Rnode_graph_set_selection_callback");
    if (graph == null) return;
    graph.*.selection_callback = callback;
    graph.*.selection_user = user_data;
}

export fn Rnode_graph_set_removed_callback(id: raven.Rid, callback: raven.RNodeGraphItemCallback, user_data: ?*anyopaque) void {
    const graph = nodeGraphCheck(id, "Rnode_graph_set_removed_callback");
    if (graph == null) return;
    graph.*.removed_callback = callback;
    graph.*.removed_user = user_data;
}

export fn Rnode_graph_set_activated_callback(id: raven.Rid, callback: raven.RNodeGraphItemCallback, user_data: ?*anyopaque) void {
    const graph = nodeGraphCheck(id, "Rnode_graph_set_activated_callback");
    if (graph == null) return;
    graph.*.activated_callback = callback;
    graph.*.activated_user = user_data;
}

export fn Rnode_graph_set_context_callback(id: raven.Rid, callback: raven.RNodeGraphContextCallback, user_data: ?*anyopaque) void {
    const graph = nodeGraphCheck(id, "Rnode_graph_set_context_callback");
    if (graph == null) return;
    graph.*.context_callback = callback;
    graph.*.context_user = user_data;
}

export fn Rnode_graph_set_pin_multiple(id: raven.Rid, pin_id: c_int, multiple: c_int) void {
    const graph = nodeGraphCheck(id, "Rnode_graph_set_pin_multiple");
    if (graph == null) return;
    const pin = rvn_ng_pin_checked(graph, pin_id, "Rnode_graph_set_pin_multiple");
    if (pin != null and pin.*.output == 0) pin.*.multiple = @intFromBool(multiple != 0);
}

export fn Rnode_graph_set_node_active(id: raven.Rid, node_id: c_int, active: c_int) void {
    const graph = nodeGraphCheck(id, "Rnode_graph_set_node_active");
    if (graph == null) return;
    const node = rvn_ng_node_checked(graph, node_id, "Rnode_graph_set_node_active");
    const want: c_int = @intFromBool(active != 0);
    if (node == null or node.*.active == want) return;
    node.*.active = want;
    widget_h.rvn_widget_invalidate_paint(&graph.*.base);
}

export fn Rnode_graph_set_node_active_color(id: raven.Rid, node_id: c_int, r: f32, g: f32, b: f32) void {
    const graph = nodeGraphCheck(id, "Rnode_graph_set_node_active_color");
    if (graph == null) return;
    const node = rvn_ng_node_checked(graph, node_id, "Rnode_graph_set_node_active_color");
    if (node == null) return;
    node.*.active_color = base.rvn_rgba(r, g, b, 1.0);
    node.*.has_active_color = raven.R_TRUE;
    widget_h.rvn_widget_invalidate_paint(&graph.*.base);
}

export fn Rnode_graph_set_node_deletable(id: raven.Rid, node_id: c_int, deletable: c_int) void {
    const graph = nodeGraphCheck(id, "Rnode_graph_set_node_deletable");
    if (graph == null) return;
    const node = rvn_ng_node_checked(graph, node_id, "Rnode_graph_set_node_deletable");
    if (node != null) node.*.undeletable = @intFromBool(deletable == 0);
}

export fn Rnode_graph_set_node_badge(id: raven.Rid, node_id: c_int, text: [*c]const u8) void {
    const graph = nodeGraphCheck(id, "Rnode_graph_set_node_badge");
    if (graph == null) return;
    const node = rvn_ng_node_checked(graph, node_id, "Rnode_graph_set_node_badge");
    if (node == null) return;
    if ((text == null or text[0] == 0) and node.*.badge == null) return;
    if (text != null and node.*.badge != null and libc.strcmp(text, node.*.badge) == 0) return;
    if (text != null and text[0] != 0) {
        base.rvn_free(node.*.badge);
        node.*.badge = base.rvn_strdup(text);
    } else {
        // (the text stays while the pill shrinks away)
        node.*.badge[0] = 0;
    }
    widget_h.rvn_widget_invalidate_paint(&graph.*.base);
}
