// Translated to Zig from vendor/raven/examples/components/main.c (Raven, Apache-2.0). Modified by Seridian: C11 → Zig translation.
//
// Raven example - components
// Tags of your own, and documents built from C.
//
//   <Widget Name="Card" ...>   declares a tag, with parameters; then
//   <Card Title="Sales">       is used like any widget of the library
//                              (components.xml, widgets.xml)
//   <Repeat>, <ForEach>, If=   repeat and choose
//   <Include Source="...">     declarations kept in their own file
//
// From C, the "Add a card" button builds a piece of interface as a document
// (Rxml_document_..., Rxml_node_...) instead of a text: it adds elements and
// attributes, asks the library for the widgets, and shows the XML it wrote.
// Rxml_get_registered_widget_name lists the declared tags.

const std = @import("std");
const raven = @import("raven");
const example = @import("example");

pub const panic = example.panic;

// (#ifndef RAVEN_EXAMPLE_DIR / #define RAVEN_EXAMPLE_DIR ".": the module `example` always defines it.)

var app = std.mem.zeroes(struct {
    window: raven.Rid,
    cards: raven.Rid,
    status: raven.Rid,
    source: raven.Rid,
    added: c_int,
});

fn action_add(sender: raven.Rid, action: [*c]const u8, user_data: ?*anyopaque) callconv(.c) void {
    const titles = [_][*c]const u8{ "Builds", "Tickets", "Reviews", "Deploys" };
    var value: [32]u8 = undefined;
    var label: [32]u8 = undefined;
    var document: raven.Rid = undefined;
    var card: raven.Rid = undefined;
    var stat: raven.Rid = undefined;
    var button: raven.Rid = undefined;
    var widget: raven.Rid = undefined;
    var i: c_int = undefined;
    _ = sender;
    _ = action;
    _ = user_data;

    // <Card Title="..." Badge="new" Appear="Drop"> <Stat .../> <Stat .../> <Button Into="footer"/> </Card>
    document = raven.Rxml_document_create("Card");
    card = raven.Rxml_document_get_root(document);
    raven.Rxml_node_set_attribute(card, "Title", titles[@intCast(@rem(app.added, 4))]);
    raven.Rxml_node_set_attribute(card, "Badge", "new");
    raven.Rxml_node_set_attribute(card, "Appear", "Drop");
    i = 0;
    while (i < 2) : (i += 1) {
        stat = raven.Rxml_node_add_child(card, "Stat", -1);
        _ = example.snprintf(&label, label.len, @as([*:0]const u8, if (i == 0) "Open" else "Closed today"));
        _ = example.snprintf(&value, value.len, "%d", 3 + @rem(app.added * 7 + i * 11, 40));
        raven.Rxml_node_set_attribute(stat, "Label", &label);
        raven.Rxml_node_set_attribute(stat, "Value", &value);
        raven.Rxml_node_set_attribute(stat, "Trend", @as([*c]const u8, if (i == 0) "-1" else "1"));
    }
    button = raven.Rxml_node_add_child(card, "Button", -1);
    raven.Rxml_node_set_attribute(button, "Text", "Remove");
    raven.Rxml_node_set_attribute(button, "Style", "Flat");
    raven.Rxml_node_set_attribute(button, "Into", "footer");
    raven.Rxml_node_set_attribute(button, "OnClicked", "card.remove");

    // the document becomes widgets: <Card> is expanded as it would be from a file
    widget = raven.Rxml_document_create_widget(document);
    if (widget != raven.R_INVALID_ID) {
        _ = raven.Rwidget_add_child(app.cards, widget);
        app.added += 1;
        // and it can be written back as text
        raven.Rtext_editor_set_text(app.source, raven.Rxml_document_to_string(document));
        _ = example.snprintf(&value, value.len, "%d", app.added);
        raven.Rlabel_set_text(app.status, @as([*c]const u8, if (app.added == 1) "1 card added from C." else "Several cards added from C; \"Remove\" takes one away."));
    }
    raven.Rxml_document_destroy(document);
}

// The button is inside the card it removes: climb to the child of the list of cards.
fn action_remove(sender: raven.Rid, action: [*c]const u8, user_data: ?*anyopaque) callconv(.c) void {
    var widget: raven.Rid = sender;
    _ = action;
    _ = user_data;
    while (widget != raven.R_INVALID_ID and raven.Rwidget_get_parent(widget) != app.cards) widget = raven.Rwidget_get_parent(widget);
    if (widget != raven.R_INVALID_ID) raven.Rwidget_destroy(widget);
}

fn action_details(sender: raven.Rid, action: [*c]const u8, user_data: ?*anyopaque) callconv(.c) void {
    _ = sender;
    _ = action;
    _ = user_data;
    raven.Rlabel_set_text(app.status, "A button given to a card with Into=\"footer\" was clicked.");
}

export fn main() c_int {
    var text: [256]u8 = undefined;
    var i: c_int = undefined;
    var length: c_int = undefined;

    if (example.example_init("components") == 0) return 1;

    raven.Raction_bind("cards.add", action_add, null);
    raven.Raction_bind("card.remove", action_remove, null);
    raven.Raction_bind("card.details", action_details, null);

    app.window = raven.Rwindow_create_from_xml_file(example.RAVEN_EXAMPLE_DIR ++ "/components.xml");
    if (app.window == raven.R_INVALID_ID) {
        raven.Rshutdown();
        return 1;
    }
    app.cards = raven.Rwidget_find(app.window, "cards");
    app.status = raven.Rwidget_find(app.window, "status");
    app.source = raven.Rwidget_find(app.window, "source");

    // the tags the documents declared are known to the library from now on
    length = example.snprintf(&text, text.len, "Declared tags:");
    i = 0;
    while (i < raven.Rxml_get_registered_widget_count() and length < @as(c_int, text.len) - 40) : (i += 1) {
        length += example.snprintf(@as([*c]u8, &text) + @as(usize, @intCast(length)), text.len - @as(usize, @intCast(length)), " <%s>", raven.Rxml_get_registered_widget_name(i));
    }
    raven.Rlabel_set_text(app.status, &text);
    raven.Rtext_editor_set_text(app.source, "<!-- press \"Add a card\" -->");

    if (example.example_automated(app.window) == 0) {
        while (raven.Rwait_frame(-1.0) != 0) {}
    }
    raven.Rshutdown();
    return 0;
}
