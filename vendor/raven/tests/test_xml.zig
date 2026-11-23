// Translated to Zig from vendor/raven/tests/test_xml.c (Raven, Apache-2.0). Modified by Seridian: C11 → Zig translation.
//
// Raven tests - XML: parsing, building windows and widgets, error reporting.

const std = @import("std");
const raven = @import("raven");
const t = @import("test.zig");

pub const panic = t.panic;

// <stdlib.h>, <string.h> and <stdio.h> functions that test.zig does not declare
extern "c" fn getenv(name: [*c]const u8) [*c]u8;
extern "c" fn strdup(s: [*c]const u8) [*c]u8;
extern "c" fn strcspn(s: [*c]const u8, reject: [*c]const u8) usize;
extern "c" fn remove(pathname: [*c]const u8) c_int;

var g_actions: c_int = 0;
var g_sender: raven.Rid = 0;

fn on_action(sender: raven.Rid, action: [*c]const u8, user_data: ?*anyopaque) callconv(.c) void {
    _ = action;
    _ = user_data;
    g_actions += 1;
    g_sender = sender;
}

fn widget_from(xml: [*c]const u8) raven.Rid {
    return raven.Rwidget_create_from_xml(xml, t.strlen(xml));
}

fn test_window() void {
    const xml =
        "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n" ++
        "<!-- a small editor -->\n" ++
        "<Window Title=\"Editor &amp; tools\" Width=\"640\" Height=\"480\" ClearColor=\"#102030\">\n" ++
        "  <Shortcut Keys=\"Ctrl+S\" Action=\"file.save\"/>\n" ++
        "  <VBox Spacing=\"4\">\n" ++
        "    <MenuBar>\n" ++
        "      <Menu Text=\"File\">\n" ++
        "        <MenuItem Name=\"open\" Text=\"Open...\" Shortcut=\"Ctrl+O\" OnClicked=\"file.open\"/>\n" ++
        "        <Separator/>\n" ++
        "        <Menu Text=\"Recent\"><MenuItem Text=\"a.lynx\"/></Menu>\n" ++
        "      </Menu>\n" ++
        "    </MenuBar>\n" ++
        "    <HBox Slot.Fill=\"1\" Spacing=\"8\">\n" ++
        "      <Border Name=\"side\" Width=\"200\" Padding=\"8,4\" Background=\"#202020\" CornerRadius=\"6\">\n" ++
        "        <VBox>\n" ++
        "          <Label Name=\"title\">Scene &lt;1&gt;</Label>\n" ++
        "          <Button Name=\"save\" Text=\"Save\" Style=\"Primary\" OnClicked=\"file.save\" Slot.HAlign=\"Left\"/>\n" ++
        "          <Checkbox Name=\"grid\" Text=\"Grid\" Checked=\"true\"/>\n" ++
        "          <Slider Name=\"zoom\" Min=\"1\" Max=\"5\" Value=\"2.5\"/>\n" ++
        "          <ComboBox Name=\"quality\" Selected=\"1\"><Item Text=\"Low\"/><Item>High</Item></ComboBox>\n" ++
        "          <TreeView Name=\"tree\" Slot.Fill=\"1\">\n" ++
        "            <Item Text=\"World\" Expanded=\"true\"><Item Text=\"Player\"/></Item>\n" ++
        "          </TreeView>\n" ++
        "        </VBox>\n" ++
        "      </Border>\n" ++
        "      <Viewport Name=\"scene\" Slot.Fill=\"1\"/>\n" ++
        "    </HBox>\n" ++
        "  </VBox>\n" ++
        "</Window>\n";
    // sizeof(xml) - 1: the length of the text without its terminating zero
    const window = raven.Rwindow_create_from_xml(xml, xml.len);
    var w: c_int = 0;
    var h: c_int = 0;
    var pw: c_int = 0;
    var ph: c_int = 0;
    var x: f32 = undefined;
    var y: f32 = undefined;
    var fw: f32 = undefined;
    var fh: f32 = undefined;

    t.CHECK(@src(), raven.Rwindow_is_valid(window) != 0, "Rwindow_is_valid(window)");
    if (raven.Rwindow_is_valid(window) == 0) return;
    raven.Rwindow_get_size(window, &w, &h);
    t.CHECK(@src(), w == 640 and h == 480, "w == 640 && h == 480");

    const side = raven.Rwidget_find(window, "side");
    const title = raven.Rwidget_find(window, "title");
    const save = raven.Rwidget_find(window, "save");
    const scene = raven.Rwidget_find(window, "scene");
    const tree = raven.Rwidget_find(window, "tree");
    const quality = raven.Rwidget_find(window, "quality");
    t.CHECK(@src(), raven.Rwidget_get_type(side) == raven.R_WIDGET_BORDER, "Rwidget_get_type(side) == R_WIDGET_BORDER");
    t.CHECK(@src(), raven.Rwidget_get_type(scene) == raven.R_WIDGET_VIEWPORT, "Rwidget_get_type(scene) == R_WIDGET_VIEWPORT");

    // entities and text content
    t.CHECK_STR(@src(), raven.Rlabel_get_text(title), "Scene <1>", "Rlabel_get_text(title)");
    t.CHECK(@src(), raven.Rcheckbox_is_checked(raven.Rwidget_find(window, "grid")) != 0, "Rcheckbox_is_checked(Rwidget_find(window, \"grid\"))");
    t.CHECK_NEAR(@src(), raven.Rslider_get_value(raven.Rwidget_find(window, "zoom")) * 10, 25, "Rslider_get_value(Rwidget_find(window, \"zoom\")) * 10");
    t.CHECK(@src(), raven.Rcombo_box_get_item_count(quality) == 2 and raven.Rcombo_box_get_selected(quality) == 1, "Rcombo_box_get_item_count(quality) == 2 && Rcombo_box_get_selected(quality) == 1");
    t.CHECK_STR(@src(), raven.Rcombo_box_get_item_text(quality, 1), "High", "Rcombo_box_get_item_text(quality, 1)");
    t.CHECK(@src(), raven.Rtree_view_get_item_count(tree) == 1, "Rtree_view_get_item_count(tree) == 1");
    t.CHECK_STR(@src(), raven.Rtree_item_get_text(raven.Rtree_view_get_item(tree, 0)), "World", "Rtree_item_get_text(Rtree_view_get_item(tree, 0))");
    t.CHECK(@src(), raven.Rtree_item_is_expanded(raven.Rtree_view_get_item(tree, 0)) != 0, "Rtree_item_is_expanded(Rtree_view_get_item(tree, 0))");
    t.CHECK_STR(@src(), raven.Rtree_item_get_text(raven.Rtree_item_get_child(raven.Rtree_view_get_item(tree, 0), 0)), "Player", "Rtree_item_get_text(Rtree_item_get_child(Rtree_view_get_item(tree, 0), 0))");

    // layout described by the attributes
    raven.Rwidget_get_rect(side, &x, &y, &fw, &fh);
    t.CHECK_NEAR(@src(), fw, 200, "fw");
    t.CHECK_NEAR(@src(), x, 0, "x");
    raven.Rwidget_get_rect(scene, &x, &y, &fw, &fh);
    t.CHECK_NEAR(@src(), x, 208, "x");
    t.CHECK_NEAR(@src(), fw, 640 - 208, "fw");
    raven.Rviewport_get_pixel_size(scene, &pw, &ph);
    t.CHECK(@src(), pw == 640 - 208 and ph > 400, "pw == 640 - 208 && ph > 400");
    raven.Rwidget_get_rect(title, &x, &y, &fw, &fh);
    t.CHECK_NEAR(@src(), x, 8, "x");

    // actions: button click, window shortcut, menu shortcut
    raven.Raction_bind("file.save", on_action, null);
    raven.Raction_bind("file.open", on_action, null);
    g_actions = 0;
    t.test_click(window, save);
    t.CHECK(@src(), g_actions == 1 and g_sender == save, "g_actions == 1 && g_sender == save");
    t.test_key(window, raven.R_KEY_S, raven.R_MOD_CTRL);
    t.CHECK(@src(), g_actions == 2 and g_sender == window, "g_actions == 2 && g_sender == window");
    t.test_key(window, raven.R_KEY_O, raven.R_MOD_CTRL);
    t.CHECK(@src(), g_actions == 3 and g_sender == raven.Rwidget_find(window, "open"), "g_actions == 3 && g_sender == Rwidget_find(window, \"open\")");

    raven.Rwindow_destroy(window);
    t.CHECK(@src(), raven.Rwindow_is_valid(window) == 0, "!Rwindow_is_valid(window)");
    t.CHECK(@src(), raven.Rwidget_is_valid(save) == 0, "!Rwidget_is_valid(save)");
}

fn test_widget_fragment() void {
    const grid = widget_from(
        "<Grid Columns='auto,1' Rows='auto,auto' Spacing='2'>" ++
            "  <Label Text='Name' Slot.Column='0' Slot.Row='0'/>" ++
            "  <TextInput Name='name' Placeholder='type' Slot.Column='1' Slot.Row='0'/>" ++
            "  <ProgressBar Value='0.25' Slot.Column='0' Slot.Row='1' Slot.ColumnSpan='2'/>" ++
            "</Grid>",
    );
    t.CHECK(@src(), raven.Rwidget_get_type(grid) == raven.R_WIDGET_GRID, "Rwidget_get_type(grid) == R_WIDGET_GRID");
    t.CHECK(@src(), raven.Rwidget_get_child_count(grid) == 3, "Rwidget_get_child_count(grid) == 3");
    t.CHECK(@src(), raven.Rwidget_get_type(raven.Rwidget_find(grid, "name")) == raven.R_WIDGET_TEXT_INPUT, "Rwidget_get_type(Rwidget_find(grid, \"name\")) == R_WIDGET_TEXT_INPUT");
    t.CHECK_NEAR(@src(), raven.Rprogress_bar_get_value(raven.Rwidget_get_child(grid, 2)) * 100, 25, "Rprogress_bar_get_value(Rwidget_get_child(grid, 2)) * 100");
    raven.Rwidget_destroy(grid);

    // tags and attribute names are not case sensitive; Slate names are accepted
    const tabs = widget_from(
        "<tabview activetab='1'>" ++
            "  <VerticalBox slot.title='General'><textblock text='a'/></VerticalBox>" ++
            "  <ScrollBox Slot.Title='Advanced' orientation='horizontal'><Spacer Width='10' Height='10'/></ScrollBox>" ++
            "</tabview>",
    );
    t.CHECK(@src(), raven.Rwidget_get_type(tabs) == raven.R_WIDGET_TAB_VIEW, "Rwidget_get_type(tabs) == R_WIDGET_TAB_VIEW");
    t.CHECK(@src(), raven.Rtab_view_get_active(tabs) == 1, "Rtab_view_get_active(tabs) == 1");
    t.CHECK(@src(), raven.Rwidget_get_type(raven.Rwidget_get_child(tabs, 0)) == raven.R_WIDGET_VBOX, "Rwidget_get_type(Rwidget_get_child(tabs, 0)) == R_WIDGET_VBOX");
    raven.Rwidget_destroy(tabs);

    const canvas = widget_from(
        "<Canvas><Image Slot.Anchors='1,0' Slot.Alignment='1,0' Slot.Position='-4,4' Slot.Size='32,32'/>" ++
            "<![CDATA[ ignored <text> ]]></Canvas>",
    );
    t.CHECK(@src(), raven.Rwidget_get_child_count(canvas) == 1, "Rwidget_get_child_count(canvas) == 1");
    raven.Rwidget_destroy(canvas);
}

fn test_errors() void {
    t.EXPECT_ERRORS_BEGIN();
    // malformed documents
    t.CHECK(@src(), widget_from("<VBox><Label></VBox>") == raven.R_INVALID_ID, "widget_from(\"<VBox><Label></VBox>\") == R_INVALID_ID");
    t.CHECK(@src(), widget_from("<VBox") == raven.R_INVALID_ID, "widget_from(\"<VBox\") == R_INVALID_ID");
    t.CHECK(@src(), widget_from("") == raven.R_INVALID_ID, "widget_from(\"\") == R_INVALID_ID");
    t.CHECK(@src(), widget_from("<VBox attr=unquoted/>") == raven.R_INVALID_ID, "widget_from(\"<VBox attr=unquoted/>\") == R_INVALID_ID");
    t.CHECK(@src(), widget_from("<VBox/><VBox/>") == raven.R_INVALID_ID, "widget_from(\"<VBox/><VBox/>\") == R_INVALID_ID");
    t.CHECK(@src(), widget_from("<VBox>&bogus;</VBox>") == raven.R_INVALID_ID, "widget_from(\"<VBox>&bogus;</VBox>\") == R_INVALID_ID");
    // unknown widget, child in a widget that takes none, wrong root
    t.CHECK(@src(), widget_from("<VBox><Blink/></VBox>") == raven.R_INVALID_ID, "widget_from(\"<VBox><Blink/></VBox>\") == R_INVALID_ID");
    t.CHECK(@src(), widget_from("<Label><Button/></Label>") == raven.R_INVALID_ID, "widget_from(\"<Label><Button/></Label>\") == R_INVALID_ID");
    t.CHECK(@src(), widget_from("<Window/>") == raven.R_INVALID_ID, "widget_from(\"<Window/>\") == R_INVALID_ID");
    t.CHECK(@src(), raven.Rwindow_create_from_xml("<VBox/>", 7) == raven.R_INVALID_ID, "Rwindow_create_from_xml(\"<VBox/>\", 7) == R_INVALID_ID");
    t.CHECK(@src(), raven.Rwindow_create_from_xml("<Window><VBox/><VBox/></Window>", 31) == raven.R_INVALID_ID, "Rwindow_create_from_xml(\"<Window><VBox/><VBox/></Window>\", 31) == R_INVALID_ID");
    t.CHECK(@src(), raven.Rwidget_create_from_xml_file("/no/such/file.xml") == raven.R_INVALID_ID, "Rwidget_create_from_xml_file(\"/no/such/file.xml\") == R_INVALID_ID");
    t.EXPECT_ERRORS_END(@src(), 12, "g_test_errors >= (12)");

    // an unknown attribute is reported but does not stop the loading
    {
        var detail: [*c]const u8 = null;
        t.EXPECT_ERRORS_BEGIN();
        const label = widget_from("<VBox>\n  <Label Text=\"ok\" Colour=\"red\"/>\n</VBox>");
        t.EXPECT_ERRORS_END(@src(), 1, "g_test_errors >= (1)");
        t.CHECK(@src(), raven.Rwidget_is_valid(label) != 0, "Rwidget_is_valid(label)");
        t.CHECK(@src(), raven.Rerror_get_last(&detail, null) == raven.R_ERROR_XML, "Rerror_get_last(&detail, NULL) == R_ERROR_XML");
        // the message carries the position of the element
        t.CHECK(@src(), detail != null and t.strstr(detail, "line 2") != null, "detail && strstr(detail, \"line 2\") != NULL");
        t.CHECK(@src(), detail != null and t.strstr(detail, "Colour") != null, "detail && strstr(detail, \"Colour\") != NULL");
        raven.Rwidget_destroy(label);
    }
    // nothing leaked from the failed documents: no widget is left
    t.CHECK(@src(), raven.Rerror_get_last(null, null) == raven.R_NO_ERROR, "Rerror_get_last(NULL, NULL) == R_NO_ERROR");
}

// ---------------------------------------------------------------------------
//  Widgets declared in XML
// -------------------------------------------------------------------------

fn register_text(xml: [*c]const u8) c_int {
    return raven.Rxml_register_widgets(xml, t.strlen(xml));
}

fn label_of(scope: raven.Rid, name: [*c]const u8) [*c]const u8 {
    const label = raven.Rwidget_find(scope, name);
    return if (label != raven.R_INVALID_ID) raven.Rlabel_get_text(label) else "(not found)";
}

fn test_components() void {
    const library =
        "<Widgets>" ++
        "  <Widget Name=\"Field\" Label=\"Name\" Hint=\"\" Wide=\"false\">" ++
        "    <HBox Spacing=\"8\">" ++
        "      <Label Name=\"label\" Text=\"{Label}:\" Width=\"{Wide ? 140 : 90}\"/>" ++
        "      <TextInput Name=\"input\" Placeholder=\"{Hint}\" Slot.Fill=\"1\"/>" ++
        "      <Children/>" ++
        "    </HBox>" ++
        "  </Widget>" ++
        "  <Widget Name=\"Card\" Title=\"Untitled\" Count=\"0\">" ++
        "    <Border Padding=\"10\">" ++
        "      <VBox Name=\"box\">" ++
        "        <Label Name=\"title\" Text=\"{upper(Title)} ({Count * 2 + 1})\"/>" ++
        "        <Label Name=\"badge\" If=\"{Count &gt; 2}\">many</Label>" ++
        "        <Children><Label Name=\"empty\">Nothing here</Label></Children>" ++
        "        <HBox Name=\"footer\"><Children Name=\"footer\"/></HBox>" ++
        "      </VBox>" ++
        "    </Border>" ++
        "  </Widget>" ++
        "</Widgets>";
    var window: raven.Rid = undefined;
    var card: raven.Rid = undefined;

    t.CHECK(@src(), raven.Rxml_is_widget_registered("Field") == 0, "!Rxml_is_widget_registered(\"Field\")");
    t.CHECK(@src(), raven.Rxml_register_widgets(library, library.len) == 2, "Rxml_register_widgets(library, sizeof(library) - 1) == 2");
    t.CHECK(@src(), raven.Rxml_is_widget_registered("Field") != 0, "Rxml_is_widget_registered(\"Field\")");
    t.CHECK(@src(), raven.Rxml_is_widget_registered("card") != 0, "Rxml_is_widget_registered(\"card\")");
    t.CHECK(@src(), raven.Rxml_get_registered_widget_count() == 2, "Rxml_get_registered_widget_count() == 2");
    t.CHECK_STR(@src(), raven.Rxml_get_registered_widget_name(0), "Field", "Rxml_get_registered_widget_name(0)");
    t.CHECK(@src(), raven.Rxml_get_registered_widget_name(2) == null, "Rxml_get_registered_widget_name(2) == NULL");

    // the new tags are used like the built-in ones
    {
        const xml: [*c]const u8 =
            "<Window Width=\"400\" Height=\"300\">" ++
            "<VBox Name=\"rows\">" ++
            "<Field Name=\"email\" Label=\"Email\" Hint=\"you@example.com\" Slot.Padding=\"4\"/>" ++
            "<Field Name=\"password\" Label=\"Password\" Wide=\"true\"><Button Name=\"show\" Text=\"Show\"/></Field>" ++
            "<Field Name=\"plain\"/>" ++
            "</VBox></Window>";
        window = raven.Rwindow_create_from_xml(xml, t.strlen(xml));
    }
    t.CHECK(@src(), raven.Rwindow_is_valid(window) != 0, "Rwindow_is_valid(window)");
    const row = raven.Rwidget_find(window, "email");
    // the tag became the root of its body, and took the attributes that are not parameters
    t.CHECK(@src(), raven.Rwidget_get_type(row) == raven.R_WIDGET_HBOX, "Rwidget_get_type(row) == R_WIDGET_HBOX");
    t.CHECK(@src(), raven.Rwidget_get_child_count(row) == 2, "Rwidget_get_child_count(row) == 2");
    t.CHECK_STR(@src(), label_of(row, "label"), "Email:", "label_of(row, \"label\")");
    t.CHECK_STR(@src(), raven.Rtext_input_get_text(raven.Rwidget_find(row, "input")), "", "Rtext_input_get_text(Rwidget_find(row, \"input\"))");
    t.CHECK_RECT(@src(), row, 4, 4, 392, raven.Rtheme_get_metric(raven.R_METRIC_CONTROL_HEIGHT), "row");
    t.CHECK_RECT(@src(), raven.Rwidget_find(row, "label"), 4, 4, 90, raven.Rtheme_get_metric(raven.R_METRIC_CONTROL_HEIGHT), "Rwidget_find(row, \"label\")");
    // an expression of a parameter, and children given at the use
    const field = raven.Rwidget_find(window, "password");
    t.CHECK_STR(@src(), label_of(field, "label"), "Password:", "label_of(field, \"label\")");
    {
        var x: f32 = undefined;
        var y: f32 = undefined;
        var w: f32 = undefined;
        var h: f32 = undefined;
        raven.Rwidget_get_rect(raven.Rwidget_find(field, "label"), &x, &y, &w, &h);
        t.CHECK_NEAR(@src(), w, 140, "w");
    }
    t.CHECK(@src(), raven.Rwidget_get_child_count(field) == 3, "Rwidget_get_child_count(field) == 3");
    t.CHECK(@src(), raven.Rwidget_get_parent(raven.Rwidget_find(window, "show")) == field, "Rwidget_get_parent(Rwidget_find(window, \"show\")) == field");
    // default values
    t.CHECK_STR(@src(), label_of(raven.Rwidget_find(window, "plain"), "label"), "Name:", "label_of(Rwidget_find(window, \"plain\"), \"label\")");
    raven.Rwindow_destroy(window);

    // expressions, conditions, default content and named places for children
    card = widget_from("<Card Title=\"Hello\" Count=\"3\"><Button Name=\"ok\" Text=\"OK\" Into=\"footer\"/><Label Name=\"body\">Body</Label></Card>");
    t.CHECK(@src(), raven.Rwidget_get_type(card) == raven.R_WIDGET_BORDER, "Rwidget_get_type(card) == R_WIDGET_BORDER");
    const box = raven.Rwidget_find(card, "box");
    const footer = raven.Rwidget_find(card, "footer");
    t.CHECK_STR(@src(), label_of(card, "title"), "HELLO (7)", "label_of(card, \"title\")");
    t.CHECK(@src(), raven.Rwidget_find(card, "badge") != raven.R_INVALID_ID, "Rwidget_find(card, \"badge\") != R_INVALID_ID");
    t.CHECK(@src(), raven.Rwidget_find(card, "empty") == raven.R_INVALID_ID, "Rwidget_find(card, \"empty\") == R_INVALID_ID");
    t.CHECK(@src(), raven.Rwidget_get_parent(raven.Rwidget_find(card, "body")) == box, "Rwidget_get_parent(Rwidget_find(card, \"body\")) == box");
    t.CHECK(@src(), raven.Rwidget_get_parent(raven.Rwidget_find(card, "ok")) == footer, "Rwidget_get_parent(Rwidget_find(card, \"ok\")) == footer");
    t.CHECK(@src(), raven.Rwidget_get_child_count(footer) == 1, "Rwidget_get_child_count(footer) == 1");
    raven.Rwidget_destroy(card);

    card = widget_from("<Card/>");
    t.CHECK_STR(@src(), label_of(card, "title"), "UNTITLED (1)", "label_of(card, \"title\")");
    t.CHECK(@src(), raven.Rwidget_find(card, "badge") == raven.R_INVALID_ID, "Rwidget_find(card, \"badge\") == R_INVALID_ID");
    t.CHECK(@src(), raven.Rwidget_find(card, "empty") != raven.R_INVALID_ID, "Rwidget_find(card, \"empty\") != R_INVALID_ID");
    t.CHECK(@src(), raven.Rwidget_get_child_count(raven.Rwidget_find(card, "footer")) == 0, "Rwidget_get_child_count(Rwidget_find(card, \"footer\")) == 0");
    raven.Rwidget_destroy(card);

    // a declared widget uses another one, and passes its own children on
    {
        const xml: [*c]const u8 =
            "<VBox>" ++
            "<Widget Name=\"Titled\" Title=\"?\" Level=\"1\">" ++
            "  <Card Title=\"{Title} {Level}\" Count=\"{Level + 1}\"><Children/></Card>" ++
            "</Widget>" ++
            "<Titled Name=\"t\" Title=\"Deep\" Level=\"2\"><Label Name=\"inner\">in</Label></Titled>" ++
            "</VBox>";
        const root = widget_from(xml);
        t.CHECK(@src(), raven.Rwidget_get_child_count(root) == 1, "Rwidget_get_child_count(root) == 1");
        card = raven.Rwidget_find(root, "t");
        t.CHECK(@src(), raven.Rwidget_get_type(card) == raven.R_WIDGET_BORDER, "Rwidget_get_type(card) == R_WIDGET_BORDER");
        t.CHECK_STR(@src(), label_of(card, "title"), "DEEP 2 (7)", "label_of(card, \"title\")");
        t.CHECK(@src(), raven.Rwidget_find(card, "badge") != raven.R_INVALID_ID, "Rwidget_find(card, \"badge\") != R_INVALID_ID");
        t.CHECK(@src(), raven.Rwidget_get_parent(raven.Rwidget_find(card, "inner")) == raven.Rwidget_find(card, "box"), "Rwidget_get_parent(Rwidget_find(card, \"inner\")) == Rwidget_find(card, \"box\")");
        raven.Rwidget_destroy(root);
        t.CHECK(@src(), raven.Rxml_is_widget_registered("Titled") != 0, "Rxml_is_widget_registered(\"Titled\")");
    }

    // repetitions
    {
        const xml: [*c]const u8 =
            "<VBox>" ++
            "<Widget Name=\"Stars\" Count=\"3\" Names=\"a|b\">" ++
            "  <HBox>" ++
            "    <Repeat Count=\"{Count}\" Var=\"i\"><Label Name=\"star{i}\" Text=\"{i + 1}/{Count}\"/></Repeat>" ++
            "    <ForEach Items=\"{Names}\" Var=\"n\"><Button Name=\"b_{n}\" Text=\"{Index}:{n}\" If=\"{n != 'skip'}\"/></ForEach>" ++
            "    <If Test=\"{Count == 0}\"><Label Name=\"none\">none</Label></If>" ++
            "    <Label Name=\"brace\" Text=\"{{literal}} {'}'}\"/>" ++
            "  </HBox>" ++
            "</Widget>" ++
            "<Stars Name=\"s3\"/>" ++
            "<Stars Name=\"s0\" Count=\"0\" Names=\"x|skip|y\"/>" ++
            "</VBox>";
        const root = widget_from(xml);
        const s3 = raven.Rwidget_find(root, "s3");
        const s0 = raven.Rwidget_find(root, "s0");
        t.CHECK(@src(), raven.Rwidget_get_child_count(s3) == 3 + 2 + 1, "Rwidget_get_child_count(s3) == 3 + 2 + 1");
        t.CHECK_STR(@src(), label_of(s3, "star0"), "1/3", "label_of(s3, \"star0\")");
        t.CHECK_STR(@src(), label_of(s3, "star2"), "3/3", "label_of(s3, \"star2\")");
        t.CHECK(@src(), raven.Rwidget_find(s3, "b_a") != raven.R_INVALID_ID and raven.Rwidget_find(s3, "b_b") != raven.R_INVALID_ID, "Rwidget_find(s3, \"b_a\") != R_INVALID_ID && Rwidget_find(s3, \"b_b\") != R_INVALID_ID");
        t.CHECK(@src(), raven.Rwidget_find(s3, "none") == raven.R_INVALID_ID, "Rwidget_find(s3, \"none\") == R_INVALID_ID");
        t.CHECK_STR(@src(), label_of(s3, "brace"), "{literal} }", "label_of(s3, \"brace\")");
        t.CHECK(@src(), raven.Rwidget_get_child_count(s0) == 2 + 1 + 1, "Rwidget_get_child_count(s0) == 2 + 1 + 1");
        t.CHECK(@src(), raven.Rwidget_find(s0, "b_x") != raven.R_INVALID_ID and raven.Rwidget_find(s0, "b_y") != raven.R_INVALID_ID, "Rwidget_find(s0, \"b_x\") != R_INVALID_ID && Rwidget_find(s0, \"b_y\") != R_INVALID_ID");
        t.CHECK(@src(), raven.Rwidget_find(s0, "b_skip") == raven.R_INVALID_ID, "Rwidget_find(s0, \"b_skip\") == R_INVALID_ID");
        t.CHECK(@src(), raven.Rwidget_find(s0, "none") != raven.R_INVALID_ID, "Rwidget_find(s0, \"none\") != R_INVALID_ID");
        raven.Rwidget_destroy(root);
    }

    // outside of a declaration, braces are only braces
    {
        const label = widget_from("<Label>int main() { return {0}; }</Label>");
        t.CHECK_STR(@src(), raven.Rlabel_get_text(label), "int main() { return {0}; }", "Rlabel_get_text(label)");
        raven.Rwidget_destroy(label);
    }

    // the text between the tags of a use is its Text
    {
        const xml: [*c]const u8 = "<VBox><Widget Name=\"Shout\" Text=\"\"><Label Text=\"{Text}!\"/></Widget>" ++
            "<Widget Name=\"Plain\"><Label/></Widget><Shout Name=\"a\">hey</Shout><Plain Name=\"b\">ho</Plain></VBox>";
        const root = widget_from(xml);
        t.CHECK_STR(@src(), label_of(root, "a"), "hey!", "label_of(root, \"a\")");
        t.CHECK_STR(@src(), label_of(root, "b"), "ho", "label_of(root, \"b\")");
        raven.Rwidget_destroy(root);
    }

    // mistakes are reported and leave nothing behind
    t.EXPECT_ERRORS_BEGIN();
    t.CHECK(@src(), widget_from("<VBox><Widget><Label/></Widget></VBox>") != raven.R_INVALID_ID, "widget_from(\"<VBox><Widget><Label/></Widget></VBox>\") != R_INVALID_ID");
    t.CHECK(@src(), register_text("<Widget Name=\"Button\"><Label/></Widget>") == 0, "register_text(\"<Widget Name=\\\"Button\\\"><Label/></Widget>\") == 0");
    t.CHECK(@src(), register_text("<Widget Name=\"Empty\"/>") == 0, "register_text(\"<Widget Name=\\\"Empty\\\"/>\") == 0");
    t.CHECK(@src(), register_text("<Widget Name=\"1x\"><Label/></Widget>") == 0, "register_text(\"<Widget Name=\\\"1x\\\"><Label/></Widget>\") == 0");
    t.CHECK(@src(), register_text("<Widget Name=\"Loop\"><Loop/></Widget>") == 1, "register_text(\"<Widget Name=\\\"Loop\\\"><Loop/></Widget>\") == 1");
    t.CHECK(@src(), widget_from("<Loop/>") == raven.R_INVALID_ID, "widget_from(\"<Loop/>\") == R_INVALID_ID");
    t.CHECK(@src(), register_text("<Widget Name=\"Two\"><Label/><Label/></Widget>") == 1, "register_text(\"<Widget Name=\\\"Two\\\"><Label/><Label/></Widget>\") == 1");
    t.CHECK(@src(), widget_from("<Two/>") == raven.R_INVALID_ID, "widget_from(\"<Two/>\") == R_INVALID_ID");
    t.CHECK(@src(), widget_from("<Widget Name=\"OnlyDeclared\"><Label/></Widget>") == raven.R_INVALID_ID, "widget_from(\"<Widget Name=\\\"OnlyDeclared\\\"><Label/></Widget>\") == R_INVALID_ID");
    t.CHECK(@src(), register_text("<Widget Name=\"Broken\"") == 0, "register_text(\"<Widget Name=\\\"Broken\\\"\") == 0");
    t.EXPECT_ERRORS_END(@src(), 8, "g_test_errors >= (8)");
    // If="..." on the use of a declared tag keeps or drops it, and is not passed on to the widget (no warning)
    {
        const xml: [*c]const u8 = "<VBox><Widget Name=\"IfChip\" T=\"\"><Label Text=\"{T}\"/></Widget>" ++
            "<Widget Name=\"IfHost\" Show=\"\"><HBox><IfChip If=\"{!empty(Show)}\" T=\"{Show}\" Name=\"chip\"/></HBox></Widget>" ++
            "<IfHost Name=\"with\" Show=\"yes\"/><IfHost Name=\"without\"/></VBox>";
        const root = widget_from(xml);
        t.CHECK(@src(), root != raven.R_INVALID_ID, "root != R_INVALID_ID");
        t.CHECK(@src(), raven.Rwidget_get_child_count(raven.Rwidget_find(root, "with")) == 1, "Rwidget_get_child_count(Rwidget_find(root, \"with\")) == 1");
        t.CHECK_STR(@src(), label_of(raven.Rwidget_find(root, "with"), "chip"), "yes", "label_of(Rwidget_find(root, \"with\"), \"chip\")");
        t.CHECK(@src(), raven.Rwidget_get_child_count(raven.Rwidget_find(root, "without")) == 0, "Rwidget_get_child_count(Rwidget_find(root, \"without\")) == 0");
        raven.Rwidget_destroy(root);
    }
    // an expression that cannot be computed gives an empty text and a warning
    t.EXPECT_ERRORS_BEGIN();
    {
        const xml: [*c]const u8 = "<VBox><Widget Name=\"Bad\" A=\"1\"><Label Text=\"[{Unknown}][{A +}][{A / 0}][{nope(A)}]\"/></Widget><Bad Name=\"bad\"/></VBox>";
        const root = widget_from(xml);
        t.CHECK_STR(@src(), label_of(root, "bad"), "[][][0][]", "label_of(root, \"bad\")");
        raven.Rwidget_destroy(root);
    }
    t.EXPECT_ERRORS_END(@src(), 3, "g_test_errors >= (3)");

    // declarations kept in a file of their own, and brought in where they are needed
    {
        const library_xml: [*c]const u8 = "<Widgets><Widget Name=\"FromFile\" Text=\"file\"><Label Text=\"from {Text}\"/></Widget></Widgets>";
        const part_xml: [*c]const u8 = "<Label Name=\"part\">a part</Label>";
        const temp: [*c]const u8 = if (getenv("TMPDIR") != null) getenv("TMPDIR") else (if (getenv("TEMP") != null) getenv("TEMP") else "/tmp");
        var library_path: [512]u8 = undefined;
        var part_path: [512]u8 = undefined;
        var xml: [1400]u8 = undefined;
        var root: raven.Rid = undefined;
        _ = t.snprintf(&library_path, library_path.len, "%s/raven_test_library.xml", temp);
        _ = t.snprintf(&part_path, part_path.len, "%s/raven_test_part.xml", temp);
        t.CHECK(@src(), raven.Rfile_write(&library_path, library_xml, t.strlen(library_xml)) != 0, "Rfile_write(library_path, library_xml, strlen(library_xml))");
        t.CHECK(@src(), raven.Rfile_write(&part_path, part_xml, t.strlen(part_xml)) != 0, "Rfile_write(part_path, part_xml, strlen(part_xml))");
        _ = t.snprintf(&xml, xml.len, "<VBox><Include Source=\"%s\"/><Include Source=\"%s\"/><FromFile Name=\"used\"/></VBox>", &library_path, &part_path);
        root = widget_from(&xml);
        t.CHECK(@src(), raven.Rwidget_get_child_count(root) == 2, "Rwidget_get_child_count(root) == 2");
        t.CHECK_STR(@src(), label_of(root, "part"), "a part", "label_of(root, \"part\")");
        t.CHECK_STR(@src(), label_of(root, "used"), "from file", "label_of(root, \"used\")");
        raven.Rwidget_destroy(root);
        raven.Rxml_unregister_widget("FromFile");
        t.CHECK(@src(), raven.Rxml_register_widgets_from_file(&library_path) == 1, "Rxml_register_widgets_from_file(library_path) == 1");
        t.CHECK(@src(), raven.Rxml_is_widget_registered("FromFile") != 0, "Rxml_is_widget_registered(\"FromFile\")");
        _ = remove(&library_path);
        _ = remove(&part_path);
        t.EXPECT_ERRORS_BEGIN();
        t.CHECK(@src(), raven.Rxml_register_widgets_from_file(&library_path) == 0, "Rxml_register_widgets_from_file(library_path) == 0");
        root = widget_from(&xml);
        t.CHECK(@src(), root != raven.R_INVALID_ID and raven.Rwidget_get_child_count(root) == 1, "root != R_INVALID_ID && Rwidget_get_child_count(root) == 1");
        raven.Rwidget_destroy(root);
        t.EXPECT_ERRORS_END(@src(), 3, "g_test_errors >= (3)");
    }

    // declaring a name again replaces it; a name can be forgotten
    t.CHECK(@src(), register_text("<Widget Name=\"Two\"><Label Text=\"second\"/></Widget>") == 1, "register_text(\"<Widget Name=\\\"Two\\\"><Label Text=\\\"second\\\"/></Widget>\") == 1");
    card = widget_from("<Two/>");
    t.CHECK_STR(@src(), raven.Rlabel_get_text(card), "second", "Rlabel_get_text(card)");
    raven.Rwidget_destroy(card);
    raven.Rxml_unregister_widget("Two");
    raven.Rxml_unregister_widget("never declared");
    t.CHECK(@src(), raven.Rxml_is_widget_registered("Two") == 0, "!Rxml_is_widget_registered(\"Two\")");
    t.EXPECT_ERRORS_BEGIN();
    t.CHECK(@src(), widget_from("<Two/>") == raven.R_INVALID_ID, "widget_from(\"<Two/>\") == R_INVALID_ID");
    t.EXPECT_ERRORS_END(@src(), 1, "g_test_errors >= (1)");
}

// ---------------------------------------------------------------------------
//  Documents that can be edited
// -------------------------------------------------------------------------

fn parse_text(xml: [*c]const u8) raven.Rid {
    return raven.Rxml_document_parse(xml, t.strlen(xml), null);
}

fn test_documents() void {
    const source: [*c]const u8 =
        "<?xml version=\"1.0\"?>\n" ++
        "<!-- header -->\n" ++
        "<Window Title=\"A &amp; B\" Width=\"320\" Height=\"200\">\n" ++
        "  <VBox Name=\"box\" Spacing=\"4\">\n" ++
        "    <!-- first -->\n" ++
        "    <Label Name=\"l\">Hello &lt;you&gt;</Label>\n" ++
        "    <Button Name=\"b\" Text=\"Go\" OnClicked=\"go\"/>\n" ++
        "  </VBox>\n" ++
        "</Window>\n";
    var error_: raven.RXmlError = undefined;
    var document: raven.Rid = undefined;
    var root: raven.Rid = undefined;
    var other: raven.Rid = undefined;

    // reading
    document = parse_text(source);
    t.CHECK(@src(), raven.Rxml_document_is_valid(document) != 0, "Rxml_document_is_valid(document)");
    root = raven.Rxml_document_get_root(document);
    t.CHECK(@src(), raven.Rxml_node_is_valid(root) != 0, "Rxml_node_is_valid(root)");
    t.CHECK(@src(), raven.Rxml_node_get_document(root) == document, "Rxml_node_get_document(root) == document");
    t.CHECK_STR(@src(), raven.Rxml_node_get_tag(root), "Window", "Rxml_node_get_tag(root)");
    t.CHECK(@src(), raven.Rxml_node_get_parent(root) == raven.R_INVALID_ID, "Rxml_node_get_parent(root) == R_INVALID_ID");
    t.CHECK(@src(), raven.Rxml_node_get_index(root) == 0, "Rxml_node_get_index(root) == 0");
    t.CHECK(@src(), raven.Rxml_node_get_line(root) == 3, "Rxml_node_get_line(root) == 3");
    t.CHECK(@src(), raven.Rxml_node_get_attribute_count(root) == 3, "Rxml_node_get_attribute_count(root) == 3");
    t.CHECK_STR(@src(), raven.Rxml_node_get_attribute_name(root, 0), "Title", "Rxml_node_get_attribute_name(root, 0)");
    t.CHECK_STR(@src(), raven.Rxml_node_get_attribute_value(root, 0), "A & B", "Rxml_node_get_attribute_value(root, 0)");
    t.CHECK(@src(), raven.Rxml_node_get_attribute_name(root, 3) == null, "Rxml_node_get_attribute_name(root, 3) == NULL");
    t.CHECK(@src(), raven.Rxml_node_get_attribute_value(root, -1) == null, "Rxml_node_get_attribute_value(root, -1) == NULL");
    t.CHECK_STR(@src(), raven.Rxml_node_get_attribute(root, "width"), "320", "Rxml_node_get_attribute(root, \"width\")");
    t.CHECK(@src(), raven.Rxml_node_get_attribute(root, "Nope") == null, "Rxml_node_get_attribute(root, \"Nope\") == NULL");
    t.CHECK(@src(), raven.Rxml_node_get_child_count(root) == 1, "Rxml_node_get_child_count(root) == 1");
    const box = raven.Rxml_node_get_child(root, 0);
    t.CHECK(@src(), raven.Rxml_node_get_child(root, 1) == raven.R_INVALID_ID, "Rxml_node_get_child(root, 1) == R_INVALID_ID");
    t.CHECK(@src(), raven.Rxml_node_get_parent(box) == root, "Rxml_node_get_parent(box) == root");
    t.CHECK(@src(), raven.Rxml_node_get_child_count(box) == 3, "Rxml_node_get_child_count(box) == 3");
    const comment = raven.Rxml_node_get_child(box, 0);
    const label = raven.Rxml_node_get_child(box, 1);
    const button = raven.Rxml_node_get_child(box, 2);
    t.CHECK(@src(), raven.Rxml_node_is_comment(comment) != 0 and raven.Rxml_node_is_comment(label) == 0, "Rxml_node_is_comment(comment) && !Rxml_node_is_comment(label)");
    t.CHECK_STR(@src(), raven.Rxml_node_get_tag(comment), "", "Rxml_node_get_tag(comment)");
    t.CHECK_STR(@src(), raven.Rxml_node_get_text(comment), " first ", "Rxml_node_get_text(comment)");
    t.CHECK_STR(@src(), raven.Rxml_node_get_text(label), "Hello <you>", "Rxml_node_get_text(label)");
    t.CHECK_STR(@src(), raven.Rxml_node_get_text(button), "", "Rxml_node_get_text(button)");
    t.CHECK(@src(), raven.Rxml_node_get_index(button) == 2, "Rxml_node_get_index(button) == 2");
    t.CHECK(@src(), raven.Rxml_node_get_line(label) == 6, "Rxml_node_get_line(label) == 6");

    // writing: one element per line, tabs, what must be escaped is, comments are kept
    const text = raven.Rxml_document_to_string(document);
    t.CHECK_STR(@src(), text, "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n" ++
        "<!-- header -->\n" ++
        "<Window Title=\"A &amp; B\" Width=\"320\" Height=\"200\">\n" ++
        "\t<VBox Name=\"box\" Spacing=\"4\">\n" ++
        "\t\t<!-- first -->\n" ++
        "\t\t<Label Name=\"l\">Hello &lt;you&gt;</Label>\n" ++
        "\t\t<Button Name=\"b\" Text=\"Go\" OnClicked=\"go\"/>\n" ++
        "\t</VBox>\n" ++
        "</Window>\n", "text");
    // (written, the nodes know their new lines)
    t.CHECK(@src(), raven.Rxml_node_get_line(root) == 3 and raven.Rxml_node_get_line(button) == 7, "Rxml_node_get_line(root) == 3 && Rxml_node_get_line(button) == 7");
    // what is written reads back the same
    other = parse_text(text);
    t.CHECK(@src(), other != raven.R_INVALID_ID, "other != R_INVALID_ID");
    {
        const first = strdup(text);
        t.CHECK_STR(@src(), raven.Rxml_document_to_string(other), first, "Rxml_document_to_string(other)");
        t.free(first);
    }
    raven.Rxml_document_destroy(other);
    t.CHECK(@src(), raven.Rxml_document_is_valid(other) == 0, "!Rxml_document_is_valid(other)");

    // changing
    raven.Rxml_node_set_attribute(button, "Text", "Say \"hi\"\n<now>");
    raven.Rxml_node_set_attribute(button, "onclicked", null);
    raven.Rxml_node_set_attribute(button, "Style", "Primary");
    raven.Rxml_node_set_attribute(button, "Nope", null);
    t.CHECK(@src(), raven.Rxml_node_get_attribute_count(button) == 3, "Rxml_node_get_attribute_count(button) == 3");
    t.CHECK_STR(@src(), raven.Rxml_node_to_string(button), "<Button Name=\"b\" Text=\"Say &quot;hi&quot;&#10;&lt;now&gt;\" Style=\"Primary\"/>\n", "Rxml_node_to_string(button)");
    raven.Rxml_node_set_text(label, "");
    raven.Rxml_node_set_tag(label, "Checkbox");
    t.CHECK_STR(@src(), raven.Rxml_node_to_string(label), "<Checkbox Name=\"l\"/>\n", "Rxml_node_to_string(label)");
    raven.Rxml_node_set_text(label, "On & on");
    const added = raven.Rxml_node_add_child(box, "Slider", 0);
    t.CHECK(@src(), raven.Rxml_node_get_child(box, 0) == added and raven.Rxml_node_get_index(comment) == 1, "Rxml_node_get_child(box, 0) == added && Rxml_node_get_index(comment) == 1");
    t.CHECK(@src(), raven.Rxml_node_get_line(added) == 0, "Rxml_node_get_line(added) == 0");
    raven.Rxml_node_set_attribute(added, "Value", "0.5");
    other = raven.Rxml_node_add_comment(box, " last ", -1);
    t.CHECK(@src(), raven.Rxml_node_get_index(other) == 4, "Rxml_node_get_index(other) == 4");
    other = raven.Rxml_node_add_xml(box, "<HBox><Label Text='in'/><!-- c --></HBox>", 41, 1);
    t.CHECK(@src(), raven.Rxml_node_get_index(other) == 1, "Rxml_node_get_index(other) == 1");
    t.CHECK(@src(), raven.Rxml_node_get_child_count(other) == 2, "Rxml_node_get_child_count(other) == 2");
    t.CHECK(@src(), raven.Rxml_node_get_document(raven.Rxml_node_get_child(other, 0)) == document, "Rxml_node_get_document(Rxml_node_get_child(other, 0)) == document");
    const copy = raven.Rxml_node_duplicate(other);
    t.CHECK(@src(), raven.Rxml_node_get_index(copy) == 2 and copy != other, "Rxml_node_get_index(copy) == 2 && copy != other");
    t.CHECK_STR(@src(), raven.Rxml_node_get_attribute(raven.Rxml_node_get_child(copy, 0), "Text"), "in", "Rxml_node_get_attribute(Rxml_node_get_child(copy, 0), \"Text\")");
    // moving: inside the copy, then back out, and never into itself
    t.CHECK(@src(), raven.Rxml_node_move(button, copy, 0) != 0, "Rxml_node_move(button, copy, 0)");
    t.CHECK(@src(), raven.Rxml_node_get_parent(button) == copy and raven.Rxml_node_get_index(button) == 0, "Rxml_node_get_parent(button) == copy && Rxml_node_get_index(button) == 0");
    t.CHECK(@src(), raven.Rxml_node_get_child_count(box) == 6, "Rxml_node_get_child_count(box) == 6");
    t.CHECK(@src(), raven.Rxml_node_move(copy, button, 0) == 0, "!Rxml_node_move(copy, button, 0)");
    t.CHECK(@src(), raven.Rxml_node_move(copy, copy, 0) == 0, "!Rxml_node_move(copy, copy, 0)");
    t.CHECK(@src(), raven.Rxml_node_move(root, box, 0) == 0, "!Rxml_node_move(root, box, 0)");
    t.CHECK(@src(), raven.Rxml_node_move(button, box, -1) != 0, "Rxml_node_move(button, box, -1)");
    t.CHECK(@src(), raven.Rxml_node_get_index(button) == 6, "Rxml_node_get_index(button) == 6");
    t.CHECK(@src(), raven.Rxml_node_move(button, box, 0) != 0, "Rxml_node_move(button, box, 0)");
    t.CHECK(@src(), raven.Rxml_node_get_index(button) == 0 and raven.Rxml_node_get_index(added) == 1, "Rxml_node_get_index(button) == 0 && Rxml_node_get_index(added) == 1");
    // removing takes what is inside along
    {
        const inner = raven.Rxml_node_get_child(copy, 0);
        raven.Rxml_node_remove(copy);
        t.CHECK(@src(), raven.Rxml_node_is_valid(copy) == 0 and raven.Rxml_node_is_valid(inner) == 0, "!Rxml_node_is_valid(copy) && !Rxml_node_is_valid(inner)");
    }
    t.CHECK_STR(@src(), raven.Rxml_node_to_string(box), "<VBox Name=\"box\" Spacing=\"4\">\n" ++
        "\t<Button Name=\"b\" Text=\"Say &quot;hi&quot;&#10;&lt;now&gt;\" Style=\"Primary\"/>\n" ++
        "\t<Slider Value=\"0.5\"/>\n" ++
        "\t<HBox>\n" ++
        "\t\t<Label Text=\"in\"/>\n" ++
        "\t\t<!-- c -->\n" ++
        "\t</HBox>\n" ++
        "\t<!-- first -->\n" ++
        "\t<Checkbox Name=\"l\">On &amp; on</Checkbox>\n" ++
        "\t<!-- last -->\n" ++
        "</VBox>\n", "Rxml_node_to_string(box)");

    // what cannot be done
    t.EXPECT_ERRORS_BEGIN();
    raven.Rxml_node_remove(root);
    t.CHECK(@src(), raven.Rxml_node_is_valid(root) != 0, "Rxml_node_is_valid(root)");
    t.CHECK(@src(), raven.Rxml_node_duplicate(root) == raven.R_INVALID_ID, "Rxml_node_duplicate(root) == R_INVALID_ID");
    t.CHECK(@src(), raven.Rxml_node_add_child(box, "1bad", -1) == raven.R_INVALID_ID, "Rxml_node_add_child(box, \"1bad\", -1) == R_INVALID_ID");
    t.CHECK(@src(), raven.Rxml_node_add_child(box, "", -1) == raven.R_INVALID_ID, "Rxml_node_add_child(box, \"\", -1) == R_INVALID_ID");
    t.CHECK(@src(), raven.Rxml_node_add_child(comment, "Label", -1) == raven.R_INVALID_ID, "Rxml_node_add_child(comment, \"Label\", -1) == R_INVALID_ID");
    t.CHECK(@src(), raven.Rxml_node_add_comment(box, "a -- b", -1) == raven.R_INVALID_ID, "Rxml_node_add_comment(box, \"a -- b\", -1) == R_INVALID_ID");
    t.CHECK(@src(), raven.Rxml_node_add_xml(box, "<Open>", 6, -1) == raven.R_INVALID_ID, "Rxml_node_add_xml(box, \"<Open>\", 6, -1) == R_INVALID_ID");
    raven.Rxml_node_set_tag(box, "a b");
    raven.Rxml_node_set_tag(comment, "Label");
    raven.Rxml_node_set_attribute(box, "a b", "1");
    raven.Rxml_node_set_attribute(comment, "A", "1");
    t.CHECK_STR(@src(), raven.Rxml_node_get_tag(box), "VBox", "Rxml_node_get_tag(box)");
    t.CHECK(@src(), raven.Rxml_node_get_attribute_count(box) == 2, "Rxml_node_get_attribute_count(box) == 2");
    t.CHECK(@src(), raven.Rxml_node_get_child_count(box) == 6, "Rxml_node_get_child_count(box) == 6");
    t.CHECK(@src(), raven.Rxml_document_create("no good") == raven.R_INVALID_ID, "Rxml_document_create(\"no good\") == R_INVALID_ID");
    t.CHECK(@src(), raven.Rxml_document_get_root(0x12345) == raven.R_INVALID_ID, "Rxml_document_get_root(0x12345) == R_INVALID_ID");
    t.CHECK_STR(@src(), raven.Rxml_node_get_tag(0x12345), "", "Rxml_node_get_tag(0x12345)");
    t.CHECK(@src(), parse_text("<A><B></A>") == raven.R_INVALID_ID, "parse_text(\"<A><B></A>\") == R_INVALID_ID");
    t.CHECK(@src(), raven.Rxml_document_load("/nonexistent/file.xml") == raven.R_INVALID_ID, "Rxml_document_load(\"/nonexistent/file.xml\") == R_INVALID_ID");
    t.EXPECT_ERRORS_END(@src(), 16, "g_test_errors >= (16)");
    // a mistake in the text, told to the caller instead of the error callback
    t.CHECK(@src(), raven.Rxml_document_parse("<A>\n  <B></A>", 13, &error_) == raven.R_INVALID_ID, "Rxml_document_parse(\"<A>\\n  <B></A>\", 13, &error) == R_INVALID_ID");
    t.CHECK(@src(), error_.line == 2 and error_.column > 1 and t.strstr(&error_.message, "does not match") != null, "error.line == 2 && error.column > 1 && strstr(error.message, \"does not match\") != NULL");
    t.CHECK(@src(), raven.Rxml_document_parse("<A/>", 4, &error_) != raven.R_INVALID_ID, "Rxml_document_parse(\"<A/>\", 4, &error) != R_INVALID_ID");
    t.CHECK(@src(), error_.line == 0 and error_.message[0] == 0, "error.line == 0 && error.message[0] == '\\0'");

    // building: the widgets and the nodes know each other
    {
        const widget = raven.Rxml_document_create_widget(document);
        t.CHECK(@src(), raven.Rwidget_is_valid(widget) != 0, "Rwidget_is_valid(widget)");
        // (the root is a <Window>: this is what it would show)
        t.CHECK(@src(), raven.Rwidget_get_type(widget) == raven.R_WIDGET_VBOX, "Rwidget_get_type(widget) == R_WIDGET_VBOX");
        t.CHECK(@src(), raven.Rwidget_get_xml_node(widget) == box, "Rwidget_get_xml_node(widget) == box");
        t.CHECK(@src(), raven.Rxml_node_get_widget(box) == widget, "Rxml_node_get_widget(box) == widget");
        t.CHECK(@src(), raven.Rxml_node_get_widget(root) == raven.R_INVALID_ID, "Rxml_node_get_widget(root) == R_INVALID_ID");
        const slider_widget = raven.Rxml_node_get_widget(added);
        t.CHECK(@src(), raven.Rwidget_get_type(slider_widget) == raven.R_WIDGET_SLIDER, "Rwidget_get_type(slider_widget) == R_WIDGET_SLIDER");
        t.CHECK(@src(), raven.Rslider_get_value(slider_widget) == 0.5, "Rslider_get_value(slider_widget) == 0.5f");
        t.CHECK(@src(), raven.Rwidget_get_xml_node(raven.Rwidget_find(widget, "b")) == button, "Rwidget_get_xml_node(Rwidget_find(widget, \"b\")) == button");
        t.CHECK(@src(), raven.Rxml_node_get_widget(comment) == raven.R_INVALID_ID, "Rxml_node_get_widget(comment) == R_INVALID_ID");
        t.CHECK(@src(), raven.Rwidget_get_xml_node(raven.R_INVALID_ID) == raven.R_INVALID_ID, "Rwidget_get_xml_node(R_INVALID_ID) == R_INVALID_ID");
        // a widget that was not built from a document, and one whose widget is gone
        {
            const plain = raven.Rbutton_create("x");
            t.CHECK(@src(), raven.Rwidget_get_xml_node(plain) == raven.R_INVALID_ID, "Rwidget_get_xml_node(plain) == R_INVALID_ID");
            raven.Rwidget_destroy(plain);
        }
        raven.Rwidget_destroy(widget);
        _ = raven.Rdraw_frame();
        t.CHECK(@src(), raven.Rxml_node_get_widget(box) == raven.R_INVALID_ID, "Rxml_node_get_widget(box) == R_INVALID_ID");

        const window = raven.Rxml_document_create_window(document);
        t.CHECK(@src(), raven.Rwindow_is_valid(window) != 0, "Rwindow_is_valid(window)");
        t.CHECK_STR(@src(), raven.Rwindow_get_title(window), "A & B", "Rwindow_get_title(window)");
        t.CHECK(@src(), raven.Rxml_node_get_widget(root) == window, "Rxml_node_get_widget(root) == window");
        t.CHECK(@src(), raven.Rwidget_get_xml_node(raven.Rwidget_find(window, "box")) == box, "Rwidget_get_xml_node(Rwidget_find(window, \"box\")) == box");
        t.CHECK(@src(), raven.Rxml_node_get_widget(button) == raven.Rwidget_find(window, "b"), "Rxml_node_get_widget(button) == Rwidget_find(window, \"b\")");
        // the document can go: what was built stays, and no longer leads to a node
        raven.Rxml_document_destroy(document);
        t.CHECK(@src(), raven.Rxml_node_is_valid(box) == 0, "!Rxml_node_is_valid(box)");
        t.CHECK(@src(), raven.Rwidget_get_xml_node(raven.Rwidget_find(window, "box")) == raven.R_INVALID_ID, "Rwidget_get_xml_node(Rwidget_find(window, \"box\")) == R_INVALID_ID");
        _ = raven.Rdraw_frame();
        raven.Rwindow_destroy(window);
    }

    // declared widgets: everything a use becomes leads to the node of the use; its children to their own
    document = parse_text(
        "<VBox>" ++
            "<Widget Name=\"DomCard\" Title=\"t\"><Border><VBox><Label Name=\"title\" Text=\"{Title}\"/><Children/></VBox></Border></Widget>" ++
            "<DomCard Name=\"one\" Title=\"One\"><Button Name=\"inner\" Text=\"x\"/></DomCard>" ++
            "<Repeat Count=\"2\" Var=\"i\"><Label Text=\"r{i}\"/></Repeat>" ++
            "</VBox>",
    );
    t.CHECK(@src(), document != raven.R_INVALID_ID, "document != R_INVALID_ID");
    {
        const widget = raven.Rxml_document_create_widget(document);
        root = raven.Rxml_document_get_root(document);
        const use = raven.Rxml_node_get_child(root, 1);
        const repeat = raven.Rxml_node_get_child(root, 2);
        t.CHECK(@src(), raven.Rwidget_is_valid(widget) != 0, "Rwidget_is_valid(widget)");
        t.CHECK(@src(), raven.Rxml_is_widget_registered("DomCard") != 0, "Rxml_is_widget_registered(\"DomCard\")");
        const card = raven.Rwidget_find(widget, "one");
        t.CHECK(@src(), raven.Rwidget_get_type(card) == raven.R_WIDGET_BORDER, "Rwidget_get_type(card) == R_WIDGET_BORDER");
        t.CHECK(@src(), raven.Rxml_node_get_widget(use) == card, "Rxml_node_get_widget(use) == card");
        t.CHECK(@src(), raven.Rwidget_get_xml_node(card) == use, "Rwidget_get_xml_node(card) == use");
        const title = raven.Rwidget_find(card, "title");
        t.CHECK_STR(@src(), raven.Rlabel_get_text(title), "One", "Rlabel_get_text(title)");
        t.CHECK(@src(), raven.Rwidget_get_xml_node(title) == use, "Rwidget_get_xml_node(title) == use");
        const inner = raven.Rwidget_find(card, "inner");
        t.CHECK(@src(), raven.Rwidget_get_xml_node(inner) == raven.Rxml_node_get_child(use, 0), "Rwidget_get_xml_node(inner) == Rxml_node_get_child(use, 0)");
        t.CHECK(@src(), raven.Rxml_node_get_widget(raven.Rxml_node_get_child(use, 0)) == inner, "Rxml_node_get_widget(Rxml_node_get_child(use, 0)) == inner");
        // a repeated element: its copies all come from the one node, which gives the first
        t.CHECK(@src(), raven.Rwidget_get_child_count(widget) == 3, "Rwidget_get_child_count(widget) == 3");
        t.CHECK(@src(), raven.Rwidget_get_xml_node(raven.Rwidget_get_child(widget, 1)) == raven.Rxml_node_get_child(repeat, 0), "Rwidget_get_xml_node(Rwidget_get_child(widget, 1)) == Rxml_node_get_child(repeat, 0)");
        t.CHECK(@src(), raven.Rwidget_get_xml_node(raven.Rwidget_get_child(widget, 2)) == raven.Rxml_node_get_child(repeat, 0), "Rwidget_get_xml_node(Rwidget_get_child(widget, 2)) == Rxml_node_get_child(repeat, 0)");
        t.CHECK(@src(), raven.Rxml_node_get_widget(raven.Rxml_node_get_child(repeat, 0)) == raven.Rwidget_get_child(widget, 1), "Rxml_node_get_widget(Rxml_node_get_child(repeat, 0)) == Rwidget_get_child(widget, 1)");
        // the declaration itself, and <Repeat>, are not widgets
        t.CHECK(@src(), raven.Rxml_node_get_widget(raven.Rxml_node_get_child(root, 0)) == raven.R_INVALID_ID, "Rxml_node_get_widget(Rxml_node_get_child(root, 0)) == R_INVALID_ID");
        t.CHECK(@src(), raven.Rxml_node_get_widget(repeat) == raven.R_INVALID_ID, "Rxml_node_get_widget(repeat) == R_INVALID_ID");
        raven.Rwidget_destroy(widget);
    }
    raven.Rxml_unregister_widget("DomCard");
    raven.Rxml_document_destroy(document);

    // a mistake in what is built is reported with the line the node has
    document = parse_text("<VBox>\n<Label/>\n<Nonsense/>\n</VBox>");
    t.EXPECT_ERRORS_BEGIN();
    t.CHECK(@src(), raven.Rxml_document_create_widget(document) == raven.R_INVALID_ID, "Rxml_document_create_widget(document) == R_INVALID_ID");
    t.EXPECT_ERRORS_END(@src(), 1, "g_test_errors >= (1)");
    raven.Rxml_document_destroy(document);

    // from nothing, to a file and back
    document = raven.Rxml_document_create("HBox");
    root = raven.Rxml_document_get_root(document);
    raven.Rxml_node_set_attribute(root, "Spacing", "6");
    raven.Rxml_node_set_text(raven.Rxml_node_add_child(root, "Label", -1), "saved");
    t.CHECK_STR(@src(), raven.Rxml_document_to_string(document), "<HBox Spacing=\"6\">\n\t<Label>saved</Label>\n</HBox>\n", "Rxml_document_to_string(document)");
    {
        const path: [*c]const u8 = "raven_test_document.xml";
        t.CHECK(@src(), raven.Rxml_document_save(document, path) != 0, "Rxml_document_save(document, path)");
        const loaded = raven.Rxml_document_load(path);
        t.CHECK(@src(), loaded != raven.R_INVALID_ID, "loaded != R_INVALID_ID");
        t.CHECK_STR(@src(), raven.Rxml_document_to_string(loaded), "<HBox Spacing=\"6\">\n\t<Label>saved</Label>\n</HBox>\n", "Rxml_document_to_string(loaded)");
        const widget = raven.Rxml_document_create_widget(loaded);
        t.CHECK(@src(), raven.Rwidget_get_type(widget) == raven.R_WIDGET_HBOX and raven.Rwidget_get_child_count(widget) == 1, "Rwidget_get_type(widget) == R_WIDGET_HBOX && Rwidget_get_child_count(widget) == 1");
        t.CHECK_STR(@src(), raven.Rlabel_get_text(raven.Rwidget_get_child(widget, 0)), "saved", "Rlabel_get_text(Rwidget_get_child(widget, 0))");
        raven.Rwidget_destroy(widget);
        raven.Rxml_document_destroy(loaded);
        _ = remove(path);
        t.EXPECT_ERRORS_BEGIN();
        t.CHECK(@src(), raven.Rxml_document_save(document, "") == 0, "!Rxml_document_save(document, \"\")");
        t.CHECK(@src(), raven.Rxml_document_save(document, "/nonexistent-folder/x.xml") == 0, "!Rxml_document_save(document, \"/nonexistent-folder/x.xml\")");
        t.EXPECT_ERRORS_END(@src(), 2, "g_test_errors >= (2)");
    }
    // (left alive on purpose: the library releases the documents it is left with)
}

/// The sample value given to an attribute of each kind.
fn schema_sample(info: [*c]const raven.RXmlAttributeInfo, buffer: [*c]u8, size: usize) [*c]const u8 {
    switch (info.*.type) {
        raven.R_XML_BOOL => return "true",
        raven.R_XML_NUMBER => return "1",
        raven.R_XML_COLOR => return "#336699",
        raven.R_XML_ACTION => return "test.action",
        raven.R_XML_NUMBERS => return "1",
        raven.R_XML_LIST => return "a|b",
        raven.R_XML_CHOICE => {
            var length: usize = strcspn(info.*.choices, "|");
            if (length >= size) length = size - 1;
            @memcpy(buffer[0..length], info.*.choices[0..length]);
            buffer[length] = 0;
            return buffer;
        },
        else => return "x",
    }
}

fn test_schema() void {
    var info: raven.RXmlAttributeInfo = undefined;
    var tag: c_int = undefined;
    var index: c_int = undefined;
    var total: c_int = 0;
    var buffer: [64]u8 = undefined;

    t.CHECK(@src(), raven.Rxml_get_tag_count() > 30, "Rxml_get_tag_count() > 30");
    t.CHECK_STR(@src(), raven.Rxml_get_tag_name(0), "Window", "Rxml_get_tag_name(0)");
    t.CHECK(@src(), raven.Rxml_get_tag_name(-1) == null and raven.Rxml_get_tag_name(raven.Rxml_get_tag_count()) == null, "Rxml_get_tag_name(-1) == NULL && Rxml_get_tag_name(Rxml_get_tag_count()) == NULL");
    t.CHECK(@src(), raven.Rxml_get_tag_children("Window") == 1, "Rxml_get_tag_children(\"Window\") == 1");
    t.CHECK(@src(), raven.Rxml_get_tag_children("VBox") == 2, "Rxml_get_tag_children(\"VBox\") == 2");
    t.CHECK(@src(), raven.Rxml_get_tag_children("Border") == 1, "Rxml_get_tag_children(\"Border\") == 1");
    t.CHECK(@src(), raven.Rxml_get_tag_children("Label") == 0, "Rxml_get_tag_children(\"Label\") == 0");
    t.CHECK(@src(), raven.Rxml_get_tag_children("textblock") == 0, "Rxml_get_tag_children(\"textblock\") == 0");
    t.CHECK(@src(), raven.Rxml_get_tag_children("NotATag") == 2, "Rxml_get_tag_children(\"NotATag\") == 2");
    t.CHECK(@src(), t.strlen(raven.Rxml_get_tag_description("button")) > 0, "strlen(Rxml_get_tag_description(\"button\")) > 0");
    t.CHECK_STR(@src(), raven.Rxml_get_tag_description("NotATag"), "", "Rxml_get_tag_description(\"NotATag\")");

    // every tag is one the loader knows, and every attribute listed for it is accepted with a value of its kind
    tag = 1;
    while (tag < raven.Rxml_get_tag_count()) : (tag += 1) {
        const name = raven.Rxml_get_tag_name(tag);
        var xml: [96]u8 = undefined;
        var widget: raven.Rid = undefined;
        var parent: raven.Rid = undefined;
        const count = raven.Rxml_get_attribute_count(name);
        var choices: c_int = undefined;
        _ = t.snprintf(&xml, xml.len, "<VBox><%s/></VBox>", name);
        parent = raven.Rwidget_create_from_xml(&xml, t.strlen(&xml));
        t.CHECK(@src(), parent != raven.R_INVALID_ID, "parent != R_INVALID_ID");
        if (parent == raven.R_INVALID_ID) continue;
        // (a menu and its items are not children like the others)
        widget = if (raven.Rwidget_get_child_count(parent) != 0) raven.Rwidget_get_child(parent, 0) else raven.R_INVALID_ID;
        if (widget == raven.R_INVALID_ID) {
            raven.Rwidget_destroy(parent);
            parent = raven.R_INVALID_ID;
            _ = t.snprintf(&xml, xml.len, "<%s/>", name);
            widget = raven.Rwidget_create_from_xml(&xml, t.strlen(&xml));
        }
        t.CHECK(@src(), widget != raven.R_INVALID_ID, "widget != R_INVALID_ID");
        t.CHECK(@src(), count > 60, "count > 60");
        t.CHECK(@src(), raven.Rxml_get_attribute_info(name, count, &info) == 0, "!Rxml_get_attribute_info(name, count, &info)");
        index = 0;
        while (index < count) : (index += 1) {
            t.CHECK(@src(), raven.Rxml_get_attribute_info(name, index, &info) != 0, "Rxml_get_attribute_info(name, index, &info)");
            t.CHECK(@src(), info.name != null and info.group != null and info.description != null, "info.name && info.group && info.description");
            t.CHECK(@src(), (info.type == raven.R_XML_CHOICE) == (info.choices != null), "(info.type == R_XML_CHOICE) == (info.choices != NULL)");
            total += 1;
            // (a file would have to exist, and a saved arrangement to be one; an effect is a name or a file)
            if (info.type == raven.R_XML_FILE or t.strcmp(info.name, "Layout") == 0 or t.strcmp(info.name, "Swatches") == 0) continue;
            if (t.strcmp(info.name, "Effect") == 0) {
                t.CHECK(@src(), raven.Rwidget_set_attribute(widget, info.name, "aurora") != 0, "Rwidget_set_attribute(widget, info.name, \"aurora\")");
                t.CHECK(@src(), raven.Rwidget_set_attribute(widget, info.name, "none") != 0, "Rwidget_set_attribute(widget, info.name, \"none\")");
                continue;
            }
            const value = schema_sample(&info, &buffer, buffer.len);
            // (some take a share below 1, some two numbers, some four)
            if (raven.Rwidget_set_attribute(widget, info.name, value) == 0 and
                !(info.type == raven.R_XML_NUMBER and raven.Rwidget_set_attribute(widget, info.name, "0.5") != 0) and
                !(info.type == raven.R_XML_NUMBERS and (raven.Rwidget_set_attribute(widget, info.name, "1,1") != 0 or
                    raven.Rwidget_set_attribute(widget, info.name, "0,0,1,1") != 0)))
            {
                t.g_test_failures += 1;
                _ = t.printf("  FAIL <%s %s=\"%s\"> is listed but not accepted\n", name, info.name, value);
            }
            t.g_test_checks += 1;
            // each of the choices, not only the first
            choices = 0;
            while (info.type == raven.R_XML_CHOICE and info.choices[@as(usize, @intCast(choices))] != 0) {
                const length: usize = strcspn(info.choices + @as(usize, @intCast(choices)), "|");
                _ = t.snprintf(&buffer, buffer.len, "%.*s", @as(c_int, @intCast(length)), info.choices + @as(usize, @intCast(choices)));
                if (raven.Rwidget_set_attribute(widget, info.name, &buffer) == 0) {
                    t.g_test_failures += 1;
                    _ = t.printf("  FAIL <%s %s=\"%s\"> is listed but not accepted\n", name, info.name, &buffer);
                }
                t.g_test_checks += 1;
                choices += @as(c_int, @intCast(length));
                if (info.choices[@as(usize, @intCast(choices))] == '|') choices += 1;
            }
        }
        raven.Rwidget_destroy(if (parent != raven.R_INVALID_ID) parent else widget);
        _ = raven.Rdraw_frame();
    }
    t.CHECK(@src(), total > 2000, "total > 2000");

    // the window: its own attributes only, each accepted
    {
        var xml: [1024]u8 = undefined;
        var length: c_int = t.snprintf(&xml, xml.len, "<Window");
        const count = raven.Rxml_get_attribute_count("Window");
        t.CHECK(@src(), count >= 10 and count < 20, "count >= 10 && count < 20");
        index = 0;
        while (index < count) : (index += 1) {
            t.CHECK(@src(), raven.Rxml_get_attribute_info("window", index, &info) != 0, "Rxml_get_attribute_info(\"window\", index, &info)");
            t.CHECK_STR(@src(), info.group, "Window", "info.group");
            if (info.type == raven.R_XML_FILE) continue;
            length += t.snprintf(@as([*c]u8, &xml) + @as(usize, @intCast(length)), xml.len - @as(usize, @intCast(length)), " %s=\"%s\"", info.name, //
                if (info.type == raven.R_XML_NUMBER) @as([*c]const u8, "300") else schema_sample(&info, &buffer, buffer.len));
        }
        _ = t.snprintf(@as([*c]u8, &xml) + @as(usize, @intCast(length)), xml.len - @as(usize, @intCast(length)), "/>");
        // (an attribute it does not know would be reported, and fail the test)
        const window = raven.Rwindow_create_from_xml(&xml, t.strlen(&xml));
        t.CHECK(@src(), raven.Rwindow_is_valid(window) != 0, "Rwindow_is_valid(window)");
        raven.Rwindow_destroy(window);
    }

    // groups, in order: the tag, Widget, Slot, Colors, Metrics
    t.CHECK(@src(), raven.Rxml_get_attribute_info("Button", 0, &info) != 0, "Rxml_get_attribute_info(\"Button\", 0, &info)");
    t.CHECK_STR(@src(), info.name, "Text", "info.name");
    t.CHECK_STR(@src(), info.group, "Button", "info.group");
    t.CHECK(@src(), info.type == raven.R_XML_TEXT, "info.type == R_XML_TEXT");
    t.CHECK(@src(), raven.Rxml_get_attribute_info("Button", 1, &info) != 0 and info.type == raven.R_XML_CHOICE, "Rxml_get_attribute_info(\"Button\", 1, &info) && info.type == R_XML_CHOICE");
    t.CHECK_STR(@src(), info.choices, "Default|Primary|Flat", "info.choices");
    t.CHECK(@src(), raven.Rxml_get_attribute_info("Button", 3, &info) != 0, "Rxml_get_attribute_info(\"Button\", 3, &info)");
    t.CHECK_STR(@src(), info.group, "Widget", "info.group");
    t.CHECK_STR(@src(), info.name, "Name", "info.name");
    t.CHECK(@src(), raven.Rxml_get_attribute_info("Button", raven.Rxml_get_attribute_count("Button") - 1, &info) != 0, "Rxml_get_attribute_info(\"Button\", Rxml_get_attribute_count(\"Button\") - 1, &info)");
    t.CHECK_STR(@src(), info.group, "Metrics", "info.group");
    t.CHECK(@src(), raven.Rxml_get_attribute_info("Button", -1, &info) == 0, "!Rxml_get_attribute_info(\"Button\", -1, &info)");
    t.CHECK(@src(), raven.Rxml_get_attribute_info(null, 0, &info) == 0, "!Rxml_get_attribute_info(NULL, 0, &info)");
    t.CHECK(@src(), raven.Rxml_get_attribute_count(null) == 0, "Rxml_get_attribute_count(NULL) == 0");

    // a tag declared with <Widget>: its parameters, with their default value as description, then what every widget has
    t.CHECK(@src(), register_text("<Widget Name=\"SchemaCard\" Title=\"Untitled\" Wide=\"false\"><Border/></Widget>") == 1, "register_text(\"<Widget Name=\\\"SchemaCard\\\" Title=\\\"Untitled\\\" Wide=\\\"false\\\"><Border/></Widget>\") == 1");
    t.CHECK(@src(), raven.Rxml_get_tag_children("SchemaCard") == 2, "Rxml_get_tag_children(\"SchemaCard\") == 2");
    t.CHECK(@src(), raven.Rxml_get_attribute_count("SchemaCard") == raven.Rxml_get_attribute_count("Spacer") + 2, "Rxml_get_attribute_count(\"SchemaCard\") == Rxml_get_attribute_count(\"Spacer\") + 2");
    t.CHECK(@src(), raven.Rxml_get_attribute_info("SchemaCard", 0, &info) != 0, "Rxml_get_attribute_info(\"SchemaCard\", 0, &info)");
    t.CHECK_STR(@src(), info.name, "Title", "info.name");
    t.CHECK_STR(@src(), info.group, "SchemaCard", "info.group");
    t.CHECK_STR(@src(), info.description, "Untitled", "info.description");
    t.CHECK(@src(), raven.Rxml_get_attribute_info("SchemaCard", 1, &info) != 0, "Rxml_get_attribute_info(\"SchemaCard\", 1, &info)");
    t.CHECK_STR(@src(), info.name, "Wide", "info.name");
    t.CHECK(@src(), raven.Rxml_get_attribute_info("SchemaCard", 2, &info) != 0, "Rxml_get_attribute_info(\"SchemaCard\", 2, &info)");
    t.CHECK_STR(@src(), info.name, "Name", "info.name");
    t.CHECK_STR(@src(), info.group, "Widget", "info.group");
    raven.Rxml_unregister_widget("SchemaCard");
}

export fn main() c_int {
    if (t.test_init(0) == 0) {
        _ = t.printf("cannot initialize Raven\n");
        return 1;
    }
    t.RUN(test_window, "test_window");
    t.RUN(test_widget_fragment, "test_widget_fragment");
    t.RUN(test_errors, "test_errors");
    t.RUN(test_components, "test_components");
    t.RUN(test_documents, "test_documents");
    t.RUN(test_schema, "test_schema");
    raven.Rshutdown();
    return t.test_report("test_xml");
}
