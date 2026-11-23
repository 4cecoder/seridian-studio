// Translated to Zig from vendor/raven/tools/designer/main.c (Raven, Apache-2.0). Modified by Seridian: C11 → Zig translation.
//
// Raven Designer - the IDE of Raven: projects built with CMake, interfaces
// edited visually (.xml and .xmlc, the interface with its C), code editors
// with completion, translations, build and run.
//
//   raven_designer [project folder | file.xml | file.xmlc]
//
// The other files: ide.h says what each one does (project, editors, xmlc,
// build, strings, os). This one is the visual editor of an interface.
//
// The window shows the same document five ways, all kept in step:
//
//   Widgets      what can be added: the tags of the library and those the
//                document declares with <Widget>
//   Tree         the elements; arrows and buttons move, wrap, copy, delete
//   Preview      the interface, built for real; a click selects an element
//   Properties   the attributes of the selected element, by kind of value
//   XML          the text itself, colored, with the mistakes underlined
//
// Everything here uses the public API of Raven only: the document is a
// Rxml_document, the lists of tags and attributes come from Rxml_get_tag_...
// and Rxml_get_attribute_..., and the preview finds the element under the
// pointer with Rwidget_pick and Rwidget_get_xml_node. The interface of the
// designer is itself described in XML (DESIGNER_XML below).
//
// For automated runs (the tests of the build use them):
//
//   --null             no window system and no GPU
//   --headless         offscreen rendering
//   --frames N         stops after N frames
//   --script "..."     commands run before the frames: see designer_script
//   --capture x.ppm    saves the last frame

const std = @import("std");
const raven = @import("raven");
const ide = @import("ide_h.zig");
const libc = @import("../sys/libc.zig");

// <stdio.h>, <stdlib.h>, <string.h>: what libc.zig does not declare
extern "c" fn fprintf(stream: ?*libc.FILE, format: [*c]const u8, ...) c_int;
extern "c" fn atof(nptr: [*c]const u8) f64;
extern "c" fn strcat(dest: [*c]u8, src: [*c]const u8) [*c]u8;

// ---------------------------------------------------------------------------
//  The interface of the designer
// ---------------------------------------------------------------------------

// (in pieces: a C compiler is only required to accept texts of 4095 characters)
const DESIGNER_XML = [_][*c]const u8{
    "<Window Title=\"Raven IDE\" Width=\"1480\" Height=\"900\" MinWidth=\"960\" MinHeight=\"600\" CustomHeader=\"true\">" ++
        "  <Widget Name=\"ToolButton\" Text=\"\" Tip=\"\" Do=\"\">" ++
        "    <Button Text=\"{Text}\" Style=\"Flat\" Tooltip=\"{Tip}\" OnClicked=\"{Do}\" Metric.PaddingX=\"8\"/>" ++
        "  </Widget>" ++
        "  <VBox>" ++
        "    <HeaderBar Name=\"header\" Title=\"\">" ++
        "      <MenuBar>" ++
        "        <Menu Text=\"File\">" ++
        "          <Menu Text=\"New\">" ++
        "            <MenuItem Text=\"Window\" Shortcut=\"Ctrl+N\" OnClicked=\"file.new.window\"/>" ++
        "            <MenuItem Text=\"Panel\" OnClicked=\"file.new.panel\"/>" ++
        "            <MenuItem Text=\"Form with declared widgets\" OnClicked=\"file.new.form\"/>" ++
        "          </Menu>" ++
        "          <MenuItem Text=\"Open...\" Shortcut=\"Ctrl+O\" OnClicked=\"file.open\"/>" ++
        "          <MenuItem Text=\"Welcome page\" OnClicked=\"file.welcome\"/>" ++
        "          <Separator/>" ++
        "          <MenuItem Text=\"Save\" Shortcut=\"Ctrl+S\" OnClicked=\"file.save\"/>" ++
        "          <MenuItem Text=\"Save as...\" Shortcut=\"Ctrl+Shift+S\" OnClicked=\"file.save_as\"/>" ++
        "          <MenuItem Text=\"Save all\" Shortcut=\"Ctrl+Alt+S\" OnClicked=\"file.save_all\"/>" ++
        "          <Separator/>" ++
        "          <MenuItem Text=\"Quit\" Shortcut=\"Ctrl+Q\" OnClicked=\"file.quit\"/>" ++
        "        </Menu>",
    "        <Menu Text=\"Edit\">" ++
        "          <MenuItem Text=\"Undo\" Shortcut=\"Ctrl+Z\" OnClicked=\"edit.undo\"/>" ++
        "          <MenuItem Text=\"Redo\" Shortcut=\"Ctrl+Y\" OnClicked=\"edit.redo\"/>" ++
        "          <Separator/>" ++
        "          <MenuItem Text=\"Duplicate\" Shortcut=\"Ctrl+D\" OnClicked=\"edit.duplicate\"/>" ++
        "          <MenuItem Text=\"Delete\" Shortcut=\"Delete\" OnClicked=\"edit.delete\"/>" ++
        "          <MenuItem Text=\"Move up\" Shortcut=\"Alt+Up\" OnClicked=\"edit.up\"/>" ++
        "          <MenuItem Text=\"Move down\" Shortcut=\"Alt+Down\" OnClicked=\"edit.down\"/>" ++
        "          <MenuItem Text=\"Move out\" Shortcut=\"Alt+Left\" OnClicked=\"edit.out\"/>" ++
        "          <MenuItem Text=\"Move into the previous\" Shortcut=\"Alt+Right\" OnClicked=\"edit.in\"/>" ++
        "          <Separator/>" ++
        "          <Menu Text=\"Wrap in\">" ++
        "            <MenuItem Text=\"VBox\" OnClicked=\"edit.wrap.VBox\"/>" ++
        "            <MenuItem Text=\"HBox\" OnClicked=\"edit.wrap.HBox\"/>" ++
        "            <MenuItem Text=\"Border\" OnClicked=\"edit.wrap.Border\"/>" ++
        "            <MenuItem Text=\"ScrollBox\" OnClicked=\"edit.wrap.ScrollBox\"/>" ++
        "            <MenuItem Text=\"Overlay\" OnClicked=\"edit.wrap.Overlay\"/>" ++
        "          </Menu>" ++
        "          <MenuItem Text=\"Unwrap\" OnClicked=\"edit.unwrap\"/>" ++
        "          <Separator/>" ++
        "          <MenuItem Text=\"Copy as XML\" Shortcut=\"Ctrl+Shift+C\" OnClicked=\"edit.copy\"/>" ++
        "          <MenuItem Text=\"Paste XML inside\" Shortcut=\"Ctrl+Shift+V\" OnClicked=\"edit.paste\"/>" ++
        "        </Menu>",
    "        <Menu Text=\"View\">" ++
        "          <MenuItem Name=\"theme.dark\" Text=\"Dark\" Checkable=\"true\" Checked=\"true\" OnClicked=\"view.theme.dark\"/>" ++
        "          <MenuItem Name=\"theme.light\" Text=\"Light\" Checkable=\"true\" OnClicked=\"view.theme.light\"/>" ++
        "          <MenuItem Name=\"theme.glass_dark\" Text=\"Dark glass\" Checkable=\"true\" OnClicked=\"view.theme.glass_dark\"/>" ++
        "          <MenuItem Name=\"theme.glass_light\" Text=\"Light glass\" Checkable=\"true\" OnClicked=\"view.theme.glass_light\"/>" ++
        "          <Separator/>" ++
        "          <MenuItem Name=\"menu.reduce_motion\" Text=\"Reduce motion\" Checkable=\"true\" OnClicked=\"view.reduce_motion\"/>" ++
        "          <MenuItem Text=\"Accessibility...\" OnClicked=\"view.accessibility\"/>" ++
        "          <Separator/>" ++
        "          <MenuItem Name=\"menu.interact\" Text=\"Use the preview\" Shortcut=\"F6\" Checkable=\"true\" OnClicked=\"view.interact\"/>" ++
        "          <MenuItem Text=\"Preview in a window\" Shortcut=\"F7\" OnClicked=\"view.run\"/>" ++
        "          <MenuItem Text=\"Preview the file\" Shortcut=\"Ctrl+Shift+P\" OnClicked=\"view.preview\"/>" ++
        "          <MenuItem Text=\"Close the preview\" OnClicked=\"view.preview.close\"/>" ++
        "          <Separator/>" ++
        "          <MenuItem Text=\"Content drawer\" Shortcut=\"Ctrl+Space\" OnClicked=\"drawer.toggle\"/>" ++
        "          <MenuItem Text=\"Reset the panels\" OnClicked=\"view.reset\"/>" ++
        "          <MenuItem Text=\"Text zoom 100 %  (Ctrl + wheel zooms)\" OnClicked=\"view.zoom.reset\"/>" ++
        "        </Menu>",
    "        <Menu Text=\"Project\">" ++
        "          <MenuItem Text=\"New project...\" Shortcut=\"Ctrl+Shift+N\" OnClicked=\"project.new\"/>" ++
        "          <MenuItem Text=\"Open folder...\" Shortcut=\"Ctrl+Shift+O\" OnClicked=\"project.open\"/>" ++
        "          <MenuItem Text=\"Content drawer\" OnClicked=\"drawer.toggle\" Tooltip=\"Ctrl+Space\"/>" ++
        "          <MenuItem Text=\"Close project\" OnClicked=\"project.close\"/>" ++
        "          <Separator/>" ++
        "          <MenuItem Text=\"Build settings...\" OnClicked=\"project.settings\"/>" ++
        "        </Menu>" ++
        "        <Menu Text=\"Build\">" ++
        "          <MenuItem Text=\"Build\" Shortcut=\"Ctrl+B\" OnClicked=\"build.build\"/>" ++
        "          <MenuItem Text=\"Build and run\" Shortcut=\"F5\" OnClicked=\"build.run\"/>" ++
        "          <MenuItem Text=\"Stop\" Shortcut=\"Ctrl+F5\" OnClicked=\"build.stop\"/>" ++
        "          <Separator/>" ++
        "          <MenuItem Text=\"Configure (CMake)\" OnClicked=\"build.configure\"/>" ++
        "          <MenuItem Text=\"Rebuild everything\" OnClicked=\"build.rebuild\"/>" ++
        "          <MenuItem Text=\"Clean\" OnClicked=\"build.clean\"/>" ++
        "        </Menu>" ++
        "      </MenuBar>" ++
        "      <HBox Name=\"header.build\" Spacing=\"6\" Slot.HAlign=\"Right\" Slot.VAlign=\"Center\" Slot.Padding=\"8,0\">" ++
        "        <Button Text=\"Build\" OnClicked=\"build.build\" Tooltip=\"Builds the project with CMake (Ctrl+B)\" Metric.ControlHeight=\"26\"/>" ++
        "        <Button Text=\"Stop\" OnClicked=\"build.stop\" Tooltip=\"Stops the build or the program (Ctrl+F5)\" Metric.ControlHeight=\"26\"/>" ++
        "        <Button Text=\"Run\" Style=\"Primary\" OnClicked=\"build.run\" Tooltip=\"Builds and runs the project (F5); without a project, opens the interface in a window\" Metric.ControlHeight=\"26\"/>" ++
        "      </HBox>" ++
        "    </HeaderBar>",
    "    <Overlay Name=\"main.overlay\" Slot.Fill=\"1\">" ++
        "    <Switcher Name=\"pages\">" ++
        "    <VBox Name=\"page.welcome\"/>" ++
        "    <VBox Name=\"page.workspace\">" ++
        "    <DockArea Name=\"dock\" Slot.Fill=\"1\">" ++
        "      <VBox Name=\"panel.preview\" Slot.Title=\"Preview\" Slot.Closable=\"false\">" ++
        "        <HBox Spacing=\"6\" Slot.Padding=\"8,6\">" ++
        "          <Checkbox Name=\"interact\" Text=\"Use the preview\" Style=\"Switch\" OnChanged=\"view.interact.switch\"" ++
        "            Tooltip=\"On: the preview reacts as the interface will. Off: a click selects.\" Slot.VAlign=\"Center\"/>" ++
        "          <ComboBox Name=\"preview.language\" Width=\"200\" Tooltip=\"The language of the preview: the tables of the project, right to left included\"/>" ++
        "          <Spacer Slot.Fill=\"1\"/>" ++
        "          <Label Name=\"stage.size\" Opacity=\"0.6\" Slot.VAlign=\"Center\"/>" ++
        "          <Button Text=\"Close\" Style=\"Flat\" OnClicked=\"view.preview.close\" Tooltip=\"Closes the preview: the file goes back to a code editor\" Slot.VAlign=\"Center\"/>" ++
        "        </HBox>" ++
        "        <Separator/>" ++
        "        <Overlay Slot.Fill=\"1\">" ++
        "          <ScrollBox Name=\"stage.scroll\" ScrollBoth=\"true\">" ++
        "            <Overlay Name=\"stage\" Slot.Padding=\"28\" Slot.HAlign=\"Center\"/>" ++
        "          </ScrollBox>" ++
        "          <VBox Name=\"stage.empty\" Spacing=\"8\" Slot.HAlign=\"Center\" Slot.VAlign=\"Center\" Visibility=\"Collapsed\">" ++
        "            <Label Text=\"No interface open\" TextSize=\"20\" Slot.HAlign=\"Center\"/>" ++
        "            <Label Text=\"Right click an interface in the content drawer (Ctrl+Space) and choose Preview, or use File &gt; New.\" Opacity=\"0.6\" Slot.HAlign=\"Center\"/>" ++
        "          </VBox>" ++
        "        </Overlay>" ++
        "      </VBox>" ++
        "      <VBox Name=\"panel.widgets\" Slot.Title=\"Widgets\" Slot.Dock=\"Left\" Slot.DockSize=\"0.2\" Slot.Closable=\"false\">" ++
        "        <TextInput Name=\"palette.filter\" Placeholder=\"Search a widget\" Slot.Padding=\"6\" OnChanged=\"palette.filter\"/>" ++
        "        <ListView Name=\"palette\" Slot.Fill=\"1\" OnActivated=\"palette.add\" Tooltip=\"Double click to add inside the selected element\"/>" ++
        "        <Button Text=\"Add to the selection\" OnClicked=\"palette.add\" Slot.Padding=\"6\"/>" ++
        "      </VBox>",
    "      <VBox Name=\"panel.tree\" Slot.Title=\"Tree\" Slot.Dock=\"Bottom\" Slot.DockTo=\"panel.widgets\" Slot.DockSize=\"0.45\" Slot.Closable=\"false\">" ++
        "        <WrapBox Spacing=\"0\" Slot.Padding=\"4,2\">" ++
        "          <ToolButton Text=\"Up\" Tip=\"Before the previous element (Alt+Up)\" Do=\"edit.up\"/>" ++
        "          <ToolButton Text=\"Down\" Tip=\"After the next element (Alt+Down)\" Do=\"edit.down\"/>" ++
        "          <ToolButton Text=\"Out\" Tip=\"Out of its parent (Alt+Left)\" Do=\"edit.out\"/>" ++
        "          <ToolButton Text=\"In\" Tip=\"Into the element before it (Alt+Right)\" Do=\"edit.in\"/>" ++
        "          <ToolButton Text=\"Copy\" Tip=\"Duplicate (Ctrl+D)\" Do=\"edit.duplicate\"/>" ++
        "          <ToolButton Text=\"Delete\" Tip=\"Delete (Delete)\" Do=\"edit.delete\"/>" ++
        "        </WrapBox>" ++
        "        <Separator/>" ++
        "        <TreeView Name=\"tree\" Slot.Fill=\"1\"/>" ++
        "      </VBox>",
    "      <VBox Name=\"panel.properties\" Slot.Title=\"Properties\" Slot.Dock=\"Right\" Slot.DockSize=\"0.27\" Slot.Closable=\"false\">" ++
        "        <VBox Slot.Padding=\"10,8\" Spacing=\"2\">" ++
        "          <Label Name=\"inspector.title\" TextSize=\"17\"/>" ++
        "          <Label Name=\"inspector.about\" Opacity=\"0.6\" Wrap=\"true\"/>" ++
        "        </VBox>" ++
        "        <Separator/>" ++
        "        <ScrollBox Slot.Fill=\"1\">" ++
        "          <VBox Name=\"inspector\" Spacing=\"4\" Slot.Padding=\"8,6\"/>" ++
        "        </ScrollBox>" ++
        "      </VBox>" ++
        "      <TextEditor Name=\"source\" Language=\"XML\" LineNumbers=\"true\" Slot.Title=\"XML\" Slot.Dock=\"Bottom\" Slot.DockTo=\"panel.preview\"" ++
        "        Slot.DockSize=\"0.36\" Slot.Closable=\"false\"/>" ++
        "      <ListView Name=\"problems\" Slot.Title=\"Problems\" Slot.Dock=\"Tab\" Slot.DockTo=\"source\" Slot.Closable=\"false\" OnActivated=\"problems.go\"/>" ++
        "      <TextEditor Name=\"output\" Slot.Title=\"Output\" Slot.Dock=\"Tab\" Slot.DockTo=\"source\" Slot.Closable=\"false\"/>" ++
        "      <ListView Name=\"build.problems\" Slot.Title=\"Build\" Slot.Dock=\"Tab\" Slot.DockTo=\"source\" Slot.Closable=\"false\" Tooltip=\"Errors and warnings of the last build: double click opens the file at the line\"/>",
    "      <VBox Name=\"panel.strings\" Slot.Title=\"Translations\" Slot.Dock=\"Tab\" Slot.DockTo=\"source\" Slot.Closable=\"false\">" ++
        "        <HBox Spacing=\"6\" Slot.Padding=\"6,4\">" ++
        "          <ComboBox Name=\"strings.file\" Width=\"170\" Tooltip=\"The CSV tables of the project\"/>" ++
        "          <TextInput Name=\"strings.filter\" Placeholder=\"Search a key or a text\" OnChanged=\"strings.filter\" Slot.Fill=\"1\"/>" ++
        "          <ToolButton Text=\"Add key\" Tip=\"A new row\" Do=\"strings.add_key\"/>" ++
        "          <TextInput Name=\"strings.language\" Placeholder=\"de, ar...\" Width=\"80\"/>" ++
        "          <ToolButton Text=\"Add language\" Tip=\"A new column, for the code typed on its left\" Do=\"strings.add_language\"/>" ++
        "          <ToolButton Text=\"New table\" Tip=\"Creates strings.csv in the project\" Do=\"strings.add_table\"/>" ++
        "          <Button Text=\"Save\" Style=\"Primary\" OnClicked=\"strings.save\"/>" ++
        "        </HBox>" ++
        "        <Separator/>" ++
        "        <ScrollBox Slot.Fill=\"1\">" ++
        "          <VBox Name=\"strings.grid\" Spacing=\"4\" Slot.Padding=\"8,6\"/>" ++
        "        </ScrollBox>" ++
        "      </VBox>" ++
        "    </DockArea>" ++
        "    <Separator/>" ++
        "    <HBox Spacing=\"12\" Slot.Padding=\"10,4\">" ++
        "      <Label Name=\"status\" Slot.Fill=\"1\" Opacity=\"0.8\"/>" ++
        "      <Label Name=\"path\" Opacity=\"0.6\"/>" ++
        "    </HBox>" ++
        "    </VBox>" ++
        "    </Switcher>" ++
        "    </Overlay>" ++
        "  </VBox>" ++
        "</Window>",
};

// ---------------------------------------------------------------------------
//  Documents to start from
// ---------------------------------------------------------------------------

const TEMPLATE_WINDOW =
    "<Window Title=\"My window\" Width=\"520\" Height=\"360\">\n" ++
    "\t<VBox Spacing=\"10\" Slot.Padding=\"16\">\n" ++
    "\t\t<Label Text=\"Hello\" TextSize=\"22\"/>\n" ++
    "\t\t<Label Text=\"Select an element, change it on the right, or type in the XML below.\" Wrap=\"true\" Opacity=\"0.7\"/>\n" ++
    "\t\t<HBox Spacing=\"8\">\n" ++
    "\t\t\t<TextInput Name=\"name\" Placeholder=\"Your name\" Slot.Fill=\"1\"/>\n" ++
    "\t\t\t<Button Name=\"ok\" Text=\"Greet\" Style=\"Primary\" OnClicked=\"app.greet\"/>\n" ++
    "\t\t</HBox>\n" ++
    "\t\t<Checkbox Text=\"Remember me\" Style=\"Switch\"/>\n" ++
    "\t\t<Slider Value=\"0.4\"/>\n" ++
    "\t\t<Spacer Slot.Fill=\"1\"/>\n" ++
    "\t\t<ProgressBar Value=\"0.6\"/>\n" ++
    "\t</VBox>\n" ++
    "</Window>\n";

const TEMPLATE_PANEL =
    "<Border Padding=\"14\" Width=\"320\">\n" ++
    "\t<VBox Spacing=\"8\">\n" ++
    "\t\t<Label Text=\"A panel\" TextSize=\"18\"/>\n" ++
    "\t\t<Separator/>\n" ++
    "\t\t<Checkbox Text=\"One\" Checked=\"true\"/>\n" ++
    "\t\t<Checkbox Text=\"Two\"/>\n" ++
    "\t\t<Button Text=\"Apply\" Slot.HAlign=\"Right\"/>\n" ++
    "\t</VBox>\n" ++
    "</Border>\n";

const TEMPLATE_FORM =
    "<Window Title=\"Sign up\" Width=\"460\" Height=\"380\">\n" ++
    "\t<!-- A tag of our own: a label and an input on one line. -->\n" ++
    "\t<Widget Name=\"Field\" Label=\"Name\" Hint=\"\">\n" ++
    "\t\t<HBox Spacing=\"10\">\n" ++
    "\t\t\t<Label Text=\"{Label}\" Width=\"90\" Slot.VAlign=\"Center\"/>\n" ++
    "\t\t\t<TextInput Placeholder=\"{Hint}\" Slot.Fill=\"1\"/>\n" ++
    "\t\t\t<Children/>\n" ++
    "\t\t</HBox>\n" ++
    "\t</Widget>\n" ++
    "\t<VBox Spacing=\"10\" Slot.Padding=\"18\">\n" ++
    "\t\t<Label Text=\"Create an account\" TextSize=\"20\"/>\n" ++
    "\t\t<Field Label=\"Name\" Hint=\"Ada Lovelace\"/>\n" ++
    "\t\t<Field Label=\"Email\" Hint=\"ada@example.com\"/>\n" ++
    "\t\t<Field Label=\"Password\">\n" ++
    "\t\t\t<Button Text=\"Show\" Style=\"Flat\"/>\n" ++
    "\t\t</Field>\n" ++
    "\t\t<Repeat Count=\"2\" Var=\"i\">\n" ++
    "\t\t\t<Checkbox Text=\"Option {i + 1}\"/>\n" ++
    "\t\t</Repeat>\n" ++
    "\t\t<Spacer Slot.Fill=\"1\"/>\n" ++
    "\t\t<Button Text=\"Sign up\" Style=\"Primary\" Slot.HAlign=\"Right\"/>\n" ++
    "\t</VBox>\n" ++
    "</Window>\n";

/// What the palette adds for a tag, when an empty element would not show.
const TEMPLATES = [_]struct { tag: [*c]const u8, xml: [*c]const u8 }{
    .{ .tag = "VBox", .xml = "<VBox Spacing=\"8\"/>" },
    .{ .tag = "HBox", .xml = "<HBox Spacing=\"8\"/>" },
    .{ .tag = "Grid", .xml = "<Grid Columns=\"1,1\" Spacing=\"8\"><Label Text=\"A\"/><Label Text=\"B\" Slot.Column=\"1\"/></Grid>" },
    .{ .tag = "UniformGrid", .xml = "<UniformGrid Columns=\"2\" Spacing=\"8\"><Button Text=\"1\"/><Button Text=\"2\"/><Button Text=\"3\"/><Button Text=\"4\"/></UniformGrid>" },
    .{ .tag = "Border", .xml = "<Border Padding=\"12\"><Label Text=\"Border\"/></Border>" },
    .{ .tag = "SizeBox", .xml = "<SizeBox Width=\"120\" Height=\"80\"><Border/></SizeBox>" },
    .{ .tag = "Spacer", .xml = "<Spacer Width=\"16\" Height=\"16\"/>" },
    .{ .tag = "ScrollBox", .xml = "<ScrollBox Height=\"120\"><VBox Spacing=\"6\"><Label Text=\"One\"/><Label Text=\"Two\"/><Label Text=\"Three\"/></VBox></ScrollBox>" },
    .{ .tag = "Splitter", .xml = "<Splitter Height=\"120\"><Label Text=\"Left\"/><Label Text=\"Right\"/></Splitter>" },
    .{ .tag = "WrapBox", .xml = "<WrapBox Spacing=\"6\"><Button Text=\"One\"/><Button Text=\"Two\"/><Button Text=\"Three\"/></WrapBox>" },
    .{ .tag = "Canvas", .xml = "<Canvas Height=\"120\"><Button Text=\"Here\" Slot.Position=\"20,20\" Slot.Size=\"80,28\"/></Canvas>" },
    .{ .tag = "Switcher", .xml = "<Switcher><Label Text=\"First\"/><Label Text=\"Second\"/></Switcher>" },
    .{ .tag = "TabView", .xml = "<TabView Height=\"140\"><Label Text=\"First tab\" Slot.Title=\"One\"/><Label Text=\"Second tab\" Slot.Title=\"Two\"/></TabView>" },
    .{ .tag = "Expander", .xml = "<Expander Title=\"More\" Expanded=\"true\"><Label Text=\"Details\"/></Expander>" },
    .{ .tag = "Label", .xml = "<Label Text=\"Label\"/>" },
    .{ .tag = "Button", .xml = "<Button Text=\"Button\"/>" },
    .{ .tag = "Checkbox", .xml = "<Checkbox Text=\"Checkbox\"/>" },
    .{ .tag = "Slider", .xml = "<Slider Value=\"0.5\"/>" },
    .{ .tag = "ProgressBar", .xml = "<ProgressBar Value=\"0.4\"/>" },
    .{ .tag = "Image", .xml = "<Image Width=\"96\" Height=\"96\"/>" },
    .{ .tag = "TextInput", .xml = "<TextInput Placeholder=\"Type here\"/>" },
    .{ .tag = "SpinBox", .xml = "<SpinBox Min=\"0\" Max=\"100\" Value=\"10\"/>" },
    .{ .tag = "ComboBox", .xml = "<ComboBox Items=\"One|Two|Three\" Selected=\"0\"/>" },
    .{ .tag = "ListView", .xml = "<ListView Items=\"One|Two|Three\" Height=\"100\"/>" },
    .{ .tag = "TreeView", .xml = "<TreeView Height=\"110\"><Item Text=\"Root\"><Item Text=\"Child\"/><Item Text=\"Other child\"/></Item></TreeView>" },
    .{ .tag = "MenuBar", .xml = "<MenuBar><Menu Text=\"File\"><MenuItem Text=\"Open\"/><Separator/><MenuItem Text=\"Quit\"/></Menu></MenuBar>" },
    .{ .tag = "Menu", .xml = "<Menu Text=\"Menu\"><MenuItem Text=\"Item\"/></Menu>" },
    .{ .tag = "MenuItem", .xml = "<MenuItem Text=\"Item\"/>" },
    .{ .tag = "Viewport", .xml = "<Viewport Width=\"160\" Height=\"100\"/>" },
    .{ .tag = "Custom", .xml = "<Custom Width=\"80\" Height=\"40\"/>" },
    .{ .tag = "TextEditor", .xml = "<TextEditor Height=\"110\" Placeholder=\"Notes\"/>" },
    .{ .tag = "HeaderBar", .xml = "<HeaderBar Title=\"Title\"/>" },
    .{ .tag = "FileBrowser", .xml = "<FileBrowser Height=\"300\"/>" },
    .{ .tag = "DockArea", .xml = "<DockArea Height=\"220\"><Label Text=\"Center\" Slot.Title=\"Main\"/><Label Text=\"Side\" Slot.Title=\"Side\" Slot.Dock=\"Left\" Slot.DockSize=\"0.3\"/></DockArea>" },
    .{ .tag = "Island", .xml = "<Island ExpandOnHover=\"true\"><Label Text=\"Island\"/><VBox Spacing=\"6\" Slot.Padding=\"8\"><Label Text=\"Unfolded\"/><Button Text=\"Action\"/></VBox></Island>" },
    .{ .tag = "BackgroundBlur", .xml = "<BackgroundBlur Style=\"Frosted\" Padding=\"12\"><Label Text=\"Blur\"/></BackgroundBlur>" },
    .{ .tag = "ColorPicker", .xml = "<ColorPicker Color=\"#3B82F6\"/>" },
    .{ .tag = "Timeline", .xml = "<Timeline Duration=\"10\" Height=\"150\"><Track Name=\"Track\"><Clip Start=\"1\" Length=\"3\" Label=\"Clip\"/><Key Time=\"6\"/></Track><Marker Time=\"5\" Label=\"Mark\"/></Timeline>" },
    .{ .tag = "NodeGraph", .xml = "<NodeGraph Height=\"220\"><Node Name=\"a\" Title=\"Source\" X=\"30\" Y=\"40\"><Output Name=\"out\" Label=\"Value\"/></Node>" ++ "<Node Name=\"b\" Title=\"Result\" X=\"260\" Y=\"70\"><Input Name=\"in\" Label=\"Value\"/></Node><Link From=\"a.out\" To=\"b.in\"/></NodeGraph>" },
    .{ .tag = "Item", .xml = "<Item Text=\"Item\"/>" },
    .{ .tag = "Shortcut", .xml = "<Shortcut Keys=\"Ctrl+S\" Action=\"file.save\"/>" },
};

/// Tags that are not widgets, and what can be written on them.
const SPECIAL_TAGS = [_]struct { tag: [*c]const u8, attributes: [*c]const u8, about: [*c]const u8 }{
    .{ .tag = "Item", .attributes = "Text", .about = "A row of the list, tree or combo box it is in." },
    .{ .tag = "Shortcut", .attributes = "Keys|Action", .about = "Keys that fire an action anywhere in the window." },
    .{ .tag = "Track", .attributes = "Name|Color|Height|Locked|Muted", .about = "A track of a Timeline: it holds Clip and Key elements." },
    .{ .tag = "Clip", .attributes = "Start|Length|End|Label|Color|Selected", .about = "Something that lasts, on a track of a Timeline." },
    .{ .tag = "Key", .attributes = "Time|Label|Color", .about = "A moment, on a track of a Timeline." },
    .{ .tag = "Marker", .attributes = "Time|Label|Color", .about = "A flag on the ruler of a Timeline." },
    .{ .tag = "Node", .attributes = "Name|Title|X|Y|Color|Selected", .about = "A node of a NodeGraph: Input and Output elements, and a widget for its inside." },
    .{ .tag = "Input", .attributes = "Name|Label|Type", .about = "A pin on the left of a Node." },
    .{ .tag = "Output", .attributes = "Name|Label|Type", .about = "A pin on the right of a Node." },
    .{ .tag = "Link", .attributes = "From|To", .about = "A wire of a NodeGraph, from \"node.output\" to \"node.input\"." },
    .{ .tag = "Type", .attributes = "Name|Color", .about = "The color of the pins of a type, in a NodeGraph." },
    .{ .tag = "Widget", .attributes = "Name", .about = "Declares a tag: its other attributes are parameters, with their default values." },
    .{ .tag = "Widgets", .attributes = "", .about = "A document of <Widget> declarations." },
    .{ .tag = "Children", .attributes = "Name", .about = "Where the elements given to a declared tag go." },
    .{ .tag = "Repeat", .attributes = "Count|Var", .about = "Repeats what it contains." },
    .{ .tag = "ForEach", .attributes = "Items|Var|Index|Separator", .about = "Repeats what it contains for each text of a list." },
    .{ .tag = "If", .attributes = "Test", .about = "Keeps what it contains when the test is true." },
    .{ .tag = "Include", .attributes = "Source", .about = "Brings in another file." },
};

// ---------------------------------------------------------------------------
//  State
// ---------------------------------------------------------------------------

const MAX_HISTORY = 200;
const MAX_PROBLEMS = 64;

/// A row of the inspector: which attribute its editor writes.
const row_t = extern struct {
    name: [72]u8,
    type: raven.RXmlValueType,
    /// Choices of its combo box: index 0 is "not set".
    choices: [*c]const u8,
    swatch: raven.Rid,
};

const problem_t = extern struct {
    text: [260]u8,
    line: c_int,
    @"error": c_int,
};

const g_t = extern struct {
    window: raven.Rid,
    dock: raven.Rid,
    source: raven.Rid,
    tree: raven.Rid,
    palette: raven.Rid,
    palette_filter: raven.Rid,
    inspector: raven.Rid,
    problems_list: raven.Rid,
    status: raven.Rid,
    path_label: raven.Rid,
    stage: raven.Rid,
    frame: raven.Rid,
    outline: raven.Rid,
    preview: raven.Rid,
    interact_switch: raven.Rid,
    context_menu: raven.Rid,
    run_window: raven.Rid,

    /// The document, and the element everything is about.
    document: raven.Rid,
    selected: raven.Rid,
    hovered: raven.Rid,

    path: [*c]u8,
    modified: c_int,
    /// The text of the editor could not be read: the document is the last one that could.
    broken: c_int,
    /// An interface is shown (R_FALSE: the preview says how to open one).
    has_document: c_int,

    /// Texts of the document, oldest first; `history_at` is the current one.
    history: [MAX_HISTORY][*c]u8,
    history_count: c_int,
    history_at: c_int,
    history_typed_at: f64,

    /// Set while the designer itself writes the text of the editor, or fills a list.
    syncing: c_int,
    parse_timer: raven.Rid,
    interact: c_int,
    quitting: c_int,

    rows: [*c]row_t,
    row_count: c_int,
    row_cap: c_int,

    problems: [MAX_PROBLEMS]problem_t,
    problem_count: c_int,
    collecting: c_int,

    /// Names of the palette as shown: what a row adds.
    palette_tags: [*c][*c]u8,
    palette_count: c_int,

    /// Where the outline of the selection is drawn: it glides to its place.
    box: [4]raven.RSpring,
    box_shown: raven.RSpring,
};
var g: g_t = std.mem.zeroes(g_t);

// what the other parts of the IDE see (ide.h)
export var g_ide_window: raven.Rid = raven.R_INVALID_ID;
export var g_ide_dock: raven.Rid = raven.R_INVALID_ID;
export var g_ide_center: raven.Rid = raven.R_INVALID_ID;
export var g_ide_dialog: raven.Rid = raven.R_INVALID_ID;
// the interface shown is the one of an .xmlc: saving goes through xmlc.c
var g_is_xmlc: c_int = 0;
//
// An .xmlc is in the XML panel whole, scripts included: the visual editor
// works on its interface element, which starts on line g_iface_offset + 1
// of the file. The lines of the document are lines of that element.
//
var g_iface_offset: c_int = 0;

// The interface of a text: the text itself, or for an .xmlc its interface element (malloc), NULL when there is none.
fn interface_of(text: [*c]const u8, start: [*c]usize, end: [*c]usize) [*c]u8 {
    var out: [*c]u8 = undefined;
    var line: c_int = 1;
    start.* = 0;
    end.* = libc.strlen(text);
    if (g_is_xmlc == 0) {
        g_iface_offset = 0;
        out = @ptrCast(libc.malloc(end.* + 1));
        _ = libc.memcpy(out, text, end.* + 1);
        return out;
    }
    if (ide.xmlc_find_interface(text, start, end, &line) <= 0) return null;
    g_iface_offset = line - 1;
    out = @ptrCast(libc.malloc(end.* - start.* + 1));
    _ = libc.memcpy(out, text + start.*, end.* - start.*);
    out[end.* - start.*] = 0;
    return out;
}

// ---------------------------------------------------------------------------
//  Small things
// ---------------------------------------------------------------------------

fn copy_text(text: [*c]const u8) [*c]u8 {
    const length: usize = libc.strlen(text) + 1;
    const copy: [*c]u8 = @ptrCast(libc.malloc(length));
    _ = libc.memcpy(copy, text, length);
    return copy;
}

fn set_status(format: [*c]const u8, ...) callconv(.c) void {
    var text: [320]u8 = undefined;
    var args = @cVaStart();
    _ = libc.vsnprintf(&text, text.len, format, &args);
    @cVaEnd(&args);
    raven.Rlabel_set_text(g.status, &text);
}

export fn ide_status(format: [*c]const u8, ...) callconv(.c) void {
    var text: [700]u8 = undefined;
    var args = @cVaStart();
    _ = libc.vsnprintf(&text, text.len, format, &args);
    @cVaEnd(&args);
    raven.Rlabel_set_text(g.status, &text);
}

fn same_text(a_: [*c]const u8, b_: [*c]const u8) c_int {
    var a = a_;
    var b = b_;
    while (a.* != 0 and b.* != 0) : ({
        a += 1;
        b += 1;
    }) {
        var x: u8 = a.*;
        var y: u8 = b.*;
        if (x >= 'A' and x <= 'Z') x = x + 32;
        if (y >= 'A' and y <= 'Z') y = y + 32;
        if (x != y) return 0;
    }
    return @intFromBool(a.* == b.*);
}

fn contains_text(text: [*c]const u8, part: [*c]const u8) c_int {
    const length: usize = libc.strlen(part);
    var i: usize = undefined;
    var j: usize = undefined;
    if (length == 0) return 1;
    i = 0;
    while (text[i] != 0) : (i += 1) {
        j = 0;
        while (j < length) : (j += 1) {
            var x: u8 = text[i + j];
            var y: u8 = part[j];
            if (x >= 'A' and x <= 'Z') x = x + 32;
            if (y >= 'A' and y <= 'Z') y = y + 32;
            if (x != y) break;
        }
        if (j == length) return 1;
    }
    return 0;
}

fn special_tag(tag: [*c]const u8) c_int {
    var i: c_int = 0;
    while (i < @as(c_int, SPECIAL_TAGS.len)) : (i += 1) {
        if (same_text(SPECIAL_TAGS[@intCast(i)].tag, tag) != 0) return i;
    }
    return -1;
}

fn update_title() void {
    var title: [600]u8 = undefined;
    const name: [*c]const u8 = if (g.path != null) g.path else "Untitled";
    var slash: [*c]const u8 = libc.strrchr(name, '/');
    const backslash: [*c]const u8 = libc.strrchr(name, '\\');
    if (backslash != null and (slash == null or backslash > slash)) slash = backslash;
    if (ide.welcome_is_shown() != 0 or (g.has_document == 0 and ide.g_project_dir == null)) {
        _ = libc.snprintf(&title, title.len, "Raven IDE");
    } else if (g.has_document == 0) {
        _ = libc.snprintf(&title, title.len, "%s - Raven IDE", ide.ide_basename(ide.g_project_dir));
    } else if (ide.g_project_dir != null) {
        _ = libc.snprintf(&title, title.len, "%s%s - %s - Raven IDE", @as([*c]const u8, if (slash != null) slash + 1 else name), @as([*c]const u8, if (g.modified != 0) " *" else ""), ide.ide_basename(ide.g_project_dir));
    } else {
        _ = libc.snprintf(&title, title.len, "%s%s - Raven IDE", @as([*c]const u8, if (slash != null) slash + 1 else name), @as([*c]const u8, if (g.modified != 0) " *" else ""));
    }
    raven.Rwindow_set_title(g.window, &title);
    // (the header shows no title: the island in its middle says what is open)
    ide.island_refresh();
}

// ---------------------------------------------------------------------------
//  Problems: what the library reports while the preview is built
// ---------------------------------------------------------------------------

fn add_problem(text: [*c]const u8, line_: c_int, error_: c_int) void {
    var line = line_;
    if (g.problem_count >= MAX_PROBLEMS) return;
    const problem: [*c]problem_t = &g.problems[@intCast(g.problem_count)];
    g.problem_count += 1;
    _ = libc.snprintf(&problem.*.text, problem.*.text.len, "%s", text);
    // (in an .xmlc, the lines of the interface are lines of the file: "line 3" of the element is said as the line of the file)
    if (g_iface_offset > 0 and line > 0) {
        const at: [*c]const u8 = libc.strstr(text, "line ");
        if (at != null and at[5] >= '0' and at[5] <= '9') {
            var digits: [*c]const u8 = at + 5;
            while (digits.* >= '0' and digits.* <= '9') digits += 1;
            _ = libc.snprintf(&problem.*.text, problem.*.text.len, "%.*sline %d%s", @as(c_int, @intCast(at - text)), text, line + g_iface_offset, digits);
        }
        line += g_iface_offset;
    }
    problem.*.line = line;
    problem.*.@"error" = error_;
}

fn on_error(code: raven.RError, severity: raven.RSeverity, detail: [*c]const u8) callconv(.c) void {
    if (g.collecting != 0 and code == raven.R_ERROR_XML) {
        // "XML line 12, column 3: ..."
        const at: [*c]const u8 = libc.strstr(detail, "line ");
        add_problem(detail, if (at != null) libc.atoi(at + 5) else 0, @intFromBool(severity != raven.R_SEVERITY_WARNING));
        return;
    }
    _ = fprintf(libc.stderrFile(), "[Raven] %s (%s): %s\n", raven.Rerror_to_string(code), raven.Rseverity_to_string(severity), detail);
}

fn show_problems() void {
    var i: c_int = 0;
    raven.Rlist_view_clear_items(g.problems_list);
    raven.Rtext_editor_clear_markers(g.source);
    while (i < g.problem_count) : (i += 1) {
        const problem: [*c]const problem_t = &g.problems[@intCast(i)];
        _ = raven.Rlist_view_add_item(g.problems_list, &problem.*.text);
        if (problem.*.line > 0) {
            raven.Rtext_editor_add_marker(g.source, problem.*.line - 1, 0, -1, if (problem.*.@"error" != 0) raven.R_MARKER_ERROR else raven.R_MARKER_WARNING, &problem.*.text);
        }
    }
    if (g.problem_count == 0) {
        _ = raven.Rlist_view_add_item(g.problems_list, "No problems.");
        raven.Rdock_area_set_panel_title(g.dock, g.problems_list, "Problems");
    } else {
        var title: [32]u8 = undefined;
        _ = libc.snprintf(&title, title.len, "Problems (%d)", g.problem_count);
        raven.Rdock_area_set_panel_title(g.dock, g.problems_list, &title);
    }
}

// ---------------------------------------------------------------------------
//  Nodes
// ---------------------------------------------------------------------------

// The place of a node as the indices from the root: what survives the text being read again.
fn node_path(node: raven.Rid, path: [*c]c_int, max: c_int) c_int {
    var depth: c_int = 0;
    var i: c_int = undefined;
    var walk: raven.Rid = undefined;
    walk = node;
    while (raven.Rxml_node_get_parent(walk) != raven.R_INVALID_ID) : (walk = raven.Rxml_node_get_parent(walk)) depth += 1;
    if (depth > max) return -1;
    walk = node;
    i = depth - 1;
    while (i >= 0) : ({
        i -= 1;
        walk = raven.Rxml_node_get_parent(walk);
    }) path[@intCast(i)] = raven.Rxml_node_get_index(walk);
    return depth;
}

fn node_at_path(path: [*c]const c_int, depth: c_int) raven.Rid {
    var node: raven.Rid = raven.Rxml_document_get_root(g.document);
    var i: c_int = 0;
    while (i < depth) : (i += 1) {
        const child: raven.Rid = raven.Rxml_node_get_child(node, path[@intCast(i)]);
        if (child == raven.R_INVALID_ID) break;
        node = child;
    }
    return node;
}

// "Button  ok  \"Greet\"": what the tree and the status bar call an element.
fn node_caption(node: raven.Rid, out: [*c]u8, size: usize) void {
    var text: [*c]const u8 = undefined;
    if (raven.Rxml_node_is_comment(node) != 0) {
        _ = libc.snprintf(out, size, "<!--%.40s-->", raven.Rxml_node_get_text(node));
        return;
    }
    const name: [*c]const u8 = raven.Rxml_node_get_attribute(node, "Name");
    text = raven.Rxml_node_get_attribute(node, "Text");
    if (text == null) text = raven.Rxml_node_get_attribute(node, "Title");
    if (text == null and raven.Rxml_node_get_text(node)[0] != 0) text = raven.Rxml_node_get_text(node);
    if (name != null and text != null) {
        _ = libc.snprintf(out, size, "%s  %s  \"%.28s\"", raven.Rxml_node_get_tag(node), name, text);
    } else if (name != null) {
        _ = libc.snprintf(out, size, "%s  %s", raven.Rxml_node_get_tag(node), name);
    } else if (text != null) {
        _ = libc.snprintf(out, size, "%s  \"%.28s\"", raven.Rxml_node_get_tag(node), text);
    } else {
        _ = libc.snprintf(out, size, "%s", raven.Rxml_node_get_tag(node));
    }
}

// The widget that shows a node in the preview: its own, or the one of the nearest element around it that has one.
fn node_widget(node_: raven.Rid) raven.Rid {
    var node = node_;
    if (node == raven.R_INVALID_ID or raven.Rxml_node_is_valid(node) == 0) return raven.R_INVALID_ID;
    while (node != raven.R_INVALID_ID) : (node = raven.Rxml_node_get_parent(node)) {
        const widget: raven.Rid = raven.Rxml_node_get_widget(node);
        if (widget != raven.R_INVALID_ID and raven.Rwidget_is_valid(widget) != 0) return widget;
    }
    // the root of a window, or something in it that is not a widget (a shortcut): the frame that stands for the window
    return g.frame;
}

// ---------------------------------------------------------------------------
//  History
// ---------------------------------------------------------------------------

fn history_push(text: [*c]const u8, typed: c_int) void {
    var i: c_int = undefined;
    if (g.history_count > 0 and libc.strcmp(g.history[@intCast(g.history_at)], text) == 0) return;
    // what was undone is forgotten once something else is done
    i = g.history_at + 1;
    while (i < g.history_count) : (i += 1) libc.free(g.history[@intCast(i)]);
    if (g.history_count > 0) g.history_count = g.history_at + 1;
    // characters typed in a row are one step
    if (typed != 0 and g.history_typed_at > 0.0 and raven.Rget_time() - g.history_typed_at < 1.5 and g.history_count > 1) {
        libc.free(g.history[@intCast(g.history_at)]);
        g.history[@intCast(g.history_at)] = copy_text(text);
        g.history_typed_at = raven.Rget_time();
        return;
    }
    if (g.history_count == MAX_HISTORY) {
        libc.free(g.history[0]);
        _ = libc.memmove(&g.history, @ptrCast(@as([*c][*c]u8, &g.history) + 1), @sizeOf([*c]u8) * (MAX_HISTORY - 1));
        g.history_count -= 1;
    }
    g.history[@intCast(g.history_count)] = copy_text(text);
    g.history_count += 1;
    g.history_at = g.history_count - 1;
    g.history_typed_at = if (typed != 0) raven.Rget_time() else 0.0;
}

fn history_clear() void {
    var i: c_int = 0;
    while (i < g.history_count) : (i += 1) libc.free(g.history[@intCast(i)]);
    g.history_count = 0;
    g.history_at = 0;
    g.history_typed_at = 0.0;
}

// ---------------------------------------------------------------------------
//  Preview
// ---------------------------------------------------------------------------

fn outline_paint(widget: raven.Rid, painter: ?*raven.RPainter, width: f32, height: f32, user_data: ?*anyopaque) callconv(.c) void {
    var ox: f32 = undefined;
    var oy: f32 = undefined;
    var ow: f32 = undefined;
    var oh: f32 = undefined;
    var x: f32 = undefined;
    var y: f32 = undefined;
    var w: f32 = undefined;
    var h: f32 = undefined;
    var r: f32 = undefined;
    var gr: f32 = undefined;
    var b: f32 = undefined;
    var a: f32 = undefined;
    const target: raven.Rid = node_widget(g.selected);
    const hover: raven.Rid = if (g.interact != 0) raven.R_INVALID_ID else node_widget(g.hovered);
    _ = user_data;
    _ = width;
    _ = height;
    raven.Rwidget_get_rect(widget, &ox, &oy, &ow, &oh);
    raven.Rtheme_get_color(raven.R_COLOR_ACCENT, &r, &gr, &b, &a);

    if (hover != raven.R_INVALID_ID and hover != target) {
        raven.Rwidget_get_rect(hover, &x, &y, &w, &h);
        raven.Rdraw_rect_outline(painter, x - ox, y - oy, w, h, 3.0, 1.0, r, gr, b, 0.45);
    }
    // the frame of the selection flies from one element to the next
    const shown: f32 = raven.Rdraw_spring(painter, &g.box_shown, if (target != raven.R_INVALID_ID) 1.0 else 0.0, raven.R_MOTION_SMOOTH);
    if (target != raven.R_INVALID_ID) {
        var caption: [96]u8 = undefined;
        var text_width: f32 = 0.0;
        var text_height: f32 = 0.0;
        raven.Rwidget_get_rect(target, &x, &y, &w, &h);
        x = raven.Rdraw_spring(painter, &g.box[0], x - ox, raven.R_MOTION_BOUNCY);
        y = raven.Rdraw_spring(painter, &g.box[1], y - oy, raven.R_MOTION_BOUNCY);
        w = raven.Rdraw_spring(painter, &g.box[2], w, raven.R_MOTION_BOUNCY);
        h = raven.Rdraw_spring(painter, &g.box[3], h, raven.R_MOTION_BOUNCY);
        raven.Rdraw_rect(painter, x, y, w, h, 4.0, r, gr, b, 0.10 * shown);
        raven.Rdraw_rect_outline(painter, x - 1.0, y - 1.0, w + 2.0, h + 2.0, 5.0, 2.0, r, gr, b, shown);
        // its tag, on a tab above it (inside when there is no room)
        _ = libc.snprintf(&caption, caption.len, "%s", raven.Rxml_node_get_tag(g.selected));
        raven.Rfont_measure_text(raven.R_INVALID_ID, 11.0, &caption, &text_width, &text_height);
        const label_y: f32 = if (y - 19.0 < -24.0) y + 2.0 else y - 19.0;
        raven.Rdraw_rect(painter, x - 1.0, label_y, text_width + 12.0, 17.0, 4.0, r, gr, b, shown);
        raven.Rdraw_text(painter, raven.R_INVALID_ID, 11.0, x + 5.0, label_y + 2.0, &caption, 1.0, 1.0, 1.0, shown);
    }
}

fn node_under(x: f32, y: f32) raven.Rid {
    var widget: raven.Rid = if (g.preview != raven.R_INVALID_ID and raven.Rwidget_is_valid(g.preview) != 0) raven.Rwidget_pick(g.preview, x, y) else raven.R_INVALID_ID;
    while (widget != raven.R_INVALID_ID) {
        const node: raven.Rid = raven.Rwidget_get_xml_node(widget);
        if (node != raven.R_INVALID_ID) return node;
        if (widget == g.preview) break;
        widget = raven.Rwidget_get_parent(widget);
    }
    return raven.R_INVALID_ID;
}

fn outline_event(widget: raven.Rid, event: [*c]const raven.REvent, user_data: ?*anyopaque) callconv(.c) c_int {
    var node: raven.Rid = undefined;
    _ = user_data;
    switch (event.*.type) {
        raven.R_EVENT_MOUSE_MOVE => {
            node = node_under(event.*.x, event.*.y);
            if (node != g.hovered) {
                g.hovered = node;
                raven.Rwidget_invalidate(widget);
            }
            return raven.R_TRUE;
        },
        raven.R_EVENT_MOUSE_LEAVE => {
            g.hovered = raven.R_INVALID_ID;
            raven.Rwidget_invalidate(widget);
            return raven.R_FALSE;
        },
        raven.R_EVENT_MOUSE_DOWN => {
            raven.Rwidget_focus(widget);
            node = node_under(event.*.x, event.*.y);
            // a click outside of everything selects the root: the window itself
            if (node == raven.R_INVALID_ID) node = raven.Rxml_document_get_root(g.document);
            select_node(node, raven.R_TRUE);
            if (event.*.button == raven.R_MOUSE_RIGHT) raven.Rmenu_open(g.context_menu, g.window, event.*.x, event.*.y);
            return raven.R_TRUE;
        },
        raven.R_EVENT_MOUSE_UP => return raven.R_TRUE,
        else => return raven.R_FALSE,
    }
}

fn rebuild_preview() void {
    const root: raven.Rid = raven.Rxml_document_get_root(g.document);
    const tag: [*c]const u8 = raven.Rxml_node_get_tag(root);
    var size: [64]u8 = undefined;

    if (g.preview != raven.R_INVALID_ID and raven.Rwidget_is_valid(g.preview) != 0) raven.Rwidget_destroy(g.preview);
    g.preview = raven.R_INVALID_ID;
    g.hovered = raven.R_INVALID_ID;

    g.problem_count = 0;
    g.collecting = raven.R_TRUE;
    g.preview = raven.Rxml_document_create_widget(g.document);
    g.collecting = raven.R_FALSE;

    if (same_text(tag, "Window") != 0) {
        const width: [*c]const u8 = raven.Rxml_node_get_attribute(root, "Width");
        const height: [*c]const u8 = raven.Rxml_node_get_attribute(root, "Height");
        var w: c_int = if (width != null) libc.atoi(width) else 800;
        var h: c_int = if (height != null) libc.atoi(height) else 600;
        if (w <= 0) w = 800;
        if (h <= 0) h = 600;
        raven.Rwidget_set_size(g.frame, @floatFromInt(w), @floatFromInt(h));
        _ = libc.snprintf(&size, size.len, "%d x %d", w, h);
    } else {
        // a piece of interface: the size it asks for
        raven.Rwidget_set_size(g.frame, -1.0, -1.0);
        _ = libc.snprintf(&size, size.len, "%s", tag);
    }
    raven.Rlabel_set_text(raven.Rwidget_find(g.window, "stage.size"), &size);
    if (g.preview != raven.R_INVALID_ID) _ = raven.Rwidget_add_child(g.frame, g.preview);
    show_problems();
    raven.Rwidget_invalidate(g.outline);
}

// ---------------------------------------------------------------------------
//  Tree
// ---------------------------------------------------------------------------

fn tree_add(parent_item: raven.Rid, node: raven.Rid) void {
    var caption: [160]u8 = undefined;
    var i: c_int = undefined;
    const count: c_int = raven.Rxml_node_get_child_count(node);
    node_caption(node, &caption, caption.len);
    const item: raven.Rid = raven.Rtree_view_add_item(g.tree, parent_item, &caption);
    raven.Rtree_item_set_user_handle(item, @ptrFromInt(@as(usize, node)));
    raven.Rtree_item_set_expanded(item, raven.R_TRUE);
    if (node == g.selected) raven.Rtree_view_set_selected_item(g.tree, item);
    i = 0;
    while (i < count) : (i += 1) tree_add(item, raven.Rxml_node_get_child(node, i));
}

fn rebuild_tree() void {
    g.syncing += 1;
    raven.Rtree_view_clear_items(g.tree);
    tree_add(raven.R_INVALID_ID, raven.Rxml_document_get_root(g.document));
    g.syncing -= 1;
}

fn tree_item_of(item: raven.Rid, node: raven.Rid) raven.Rid {
    var i: c_int = undefined;
    if (item != raven.R_INVALID_ID and @as(raven.Rid, @truncate(@intFromPtr(raven.Rtree_item_get_user_handle(item)))) == node) return item;
    const count: c_int = if (item == raven.R_INVALID_ID) raven.Rtree_view_get_item_count(g.tree) else raven.Rtree_item_get_child_count(item);
    i = 0;
    while (i < count) : (i += 1) {
        const found: raven.Rid = tree_item_of(if (item == raven.R_INVALID_ID) raven.Rtree_view_get_item(g.tree, i) else raven.Rtree_item_get_child(item, i), node);
        if (found != raven.R_INVALID_ID) return found;
    }
    return raven.R_INVALID_ID;
}

fn on_tree_selected(tree: raven.Rid, item: raven.Rid, user_data: ?*anyopaque) callconv(.c) void {
    _ = tree;
    _ = user_data;
    if (g.syncing != 0 or item == raven.R_INVALID_ID) return;
    select_node(@truncate(@intFromPtr(raven.Rtree_item_get_user_handle(item))), raven.R_TRUE);
}

// ---------------------------------------------------------------------------
//  The document changed
// ---------------------------------------------------------------------------

// After the nodes were changed: the text follows, then everything that shows the document.
fn document_changed(keep_inspector: c_int) void {
    var text: [*c]const u8 = raven.Rxml_document_to_string(g.document);
    var line: c_int = if (g.selected != raven.R_INVALID_ID and raven.Rxml_node_is_valid(g.selected) != 0) raven.Rxml_node_get_line(g.selected) else 0;
    var whole: ide.ide_buffer_t = std.mem.zeroes(ide.ide_buffer_t);
    if (g_is_xmlc != 0) {
        // the element goes back in its place in the file, the scripts and the rest as they are
        const current: [*c]const u8 = raven.Rtext_editor_get_text(g.source);
        var start: usize = undefined;
        var end: usize = undefined;
        var length: usize = libc.strlen(text);
        const old: [*c]u8 = interface_of(current, &start, &end);
        while (length != 0 and (text[length - 1] == '\n' or text[length - 1] == '\r')) length -= 1;
        if (old != null) {
            ide.ide_buffer_add(&whole, current, start);
            ide.ide_buffer_add(&whole, text, length);
            ide.ide_buffer_add(&whole, current + end, libc.strlen(current + end));
            libc.free(old);
        } else {
            ide.ide_buffer_add(&whole, text, libc.strlen(text));
        }
        text = if (whole.data != null) whole.data else "";
        if (line > 0) line += g_iface_offset;
    }
    g.syncing += 1;
    raven.Rtext_editor_set_text(g.source, text);
    // the text stays on what is being changed
    if (line > 0) {
        raven.Rtext_editor_set_cursor(g.source, line - 1, 0);
        raven.Rtext_editor_scroll_to_line(g.source, line - 1);
    }
    g.syncing -= 1;
    g.broken = raven.R_FALSE;
    g.modified = raven.R_TRUE;
    history_push(text, raven.R_FALSE);
    ide.ide_buffer_free(&whole);
    rebuild_all(keep_inspector);
    update_title();
}

// ---------------------------------------------------------------------------
//  Inspector
// ---------------------------------------------------------------------------

fn add_row_record(name: [*c]const u8, type_: raven.RXmlValueType, choices: [*c]const u8) [*c]row_t {
    if (g.row_count == g.row_cap) {
        // (the editors keep pointers to their rows: the array never moves while they live)
        return null;
    }
    const row: [*c]row_t = &g.rows[@intCast(g.row_count)];
    g.row_count += 1;
    _ = libc.snprintf(&row.*.name, row.*.name.len, "%s", name);
    row.*.type = type_;
    row.*.choices = choices;
    row.*.swatch = raven.R_INVALID_ID;
    return row;
}

fn apply_value(row: [*c]row_t, value: [*c]const u8) void {
    if (g.selected == raven.R_INVALID_ID or raven.Rxml_node_is_valid(g.selected) == 0) return;
    if (libc.strcmp(&row.*.name, "#text") == 0) {
        raven.Rxml_node_set_text(g.selected, if (value != null) value else "");
    } else {
        raven.Rxml_node_set_attribute(g.selected, &row.*.name, if (value != null and value[0] != 0) value else null);
    }
    if (row.*.swatch != raven.R_INVALID_ID) _ = raven.Rwidget_set_attribute(row.*.swatch, "Background", if (value != null and value[0] != 0) value else "transparent");
    document_changed(raven.R_TRUE);
}

fn on_row_text(input: raven.Rid, text: [*c]const u8, user_data: ?*anyopaque) callconv(.c) void {
    _ = input;
    if (g.syncing == 0) apply_value(@ptrCast(@alignCast(user_data)), text);
}

fn on_row_choice(combo: raven.Rid, index: c_int, user_data: ?*anyopaque) callconv(.c) void {
    if (g.syncing == 0) apply_value(@ptrCast(@alignCast(user_data)), if (index <= 0) null else raven.Rcombo_box_get_item_text(combo, index));
}

// One line of the inspector: the name of an attribute and what edits its value.
fn add_row(box: raven.Rid, label: [*c]const u8, name: [*c]const u8, type_: raven.RXmlValueType, choices: [*c]const u8, value: [*c]const u8, tip: [*c]const u8) void {
    const row: [*c]row_t = add_row_record(name, type_, choices);
    var line: raven.Rid = undefined;
    var caption: raven.Rid = undefined;
    var editor: raven.Rid = undefined;
    if (row == null) return;
    line = raven.Rwidget_create(raven.R_WIDGET_HBOX);
    raven.Rpanel_set_spacing(line, 6.0);
    caption = raven.Rlabel_create(label);
    raven.Rwidget_set_size(caption, 104.0, -1.0);
    raven.Rslot_set_valign(caption, raven.R_VALIGN_CENTER);
    if (tip != null and tip[0] != 0) raven.Rwidget_set_tooltip(caption, tip);
    // what is set stands out from what is left to its default
    if (value == null) raven.Rwidget_set_opacity(caption, 0.6);
    _ = raven.Rwidget_add_child(line, caption);

    if (type_ == raven.R_XML_BOOL or type_ == raven.R_XML_CHOICE) {
        var list: [*c]const u8 = if (type_ == raven.R_XML_BOOL) "true|false" else choices;
        var selected: c_int = 0;
        var index: c_int = 1;
        var known: c_int = @intFromBool(value == null);
        editor = raven.Rwidget_create(raven.R_WIDGET_COMBO_BOX);
        _ = raven.Rcombo_box_add_item(editor, "(not set)");
        while (list.* != 0) {
            var item: [96]u8 = undefined;
            const length: usize = libc.strcspn(list, "|");
            _ = libc.snprintf(&item, item.len, "%.*s", @as(c_int, @intCast(length)), list);
            _ = raven.Rcombo_box_add_item(editor, &item);
            if (value != null and same_text(&item, value) != 0) {
                selected = index;
                known = raven.R_TRUE;
            }
            index += 1;
            list += length;
            if (list.* == '|') list += 1;
        }
        // a value that is none of the choices (an expression of a declared widget) is kept as it is
        if (known == 0) {
            _ = raven.Rcombo_box_add_item(editor, value);
            selected = index;
        }
        raven.Rcombo_box_set_selected(editor, selected);
        raven.Rcombo_box_set_changed_callback(editor, &on_row_choice, row);
    } else {
        editor = raven.Rwidget_create(raven.R_WIDGET_TEXT_INPUT);
        raven.Rtext_input_set_text(editor, if (value != null) value else "");
        raven.Rtext_input_set_placeholder(editor, if (type_ == raven.R_XML_NUMBER) "number" else if (type_ == raven.R_XML_COLOR) "#RRGGBB" else if (type_ == raven.R_XML_NUMBERS) "1,2" else if (type_ == raven.R_XML_ACTION) "action.name" else if (type_ == raven.R_XML_FILE) "path" else if (type_ == raven.R_XML_LIST) "One|Two" else "");
        raven.Rtext_input_set_changed_callback(editor, &on_row_text, row);
    }
    if (tip != null and tip[0] != 0) raven.Rwidget_set_tooltip(editor, tip);
    raven.Rslot_set_fill(editor, 1.0);
    _ = raven.Rwidget_add_child(line, editor);
    if (type_ == raven.R_XML_COLOR) {
        row.*.swatch = raven.Rwidget_create(raven.R_WIDGET_BORDER);
        raven.Rwidget_set_size(row.*.swatch, 22.0, 22.0);
        raven.Rslot_set_valign(row.*.swatch, raven.R_VALIGN_CENTER);
        _ = raven.Rwidget_set_attribute(row.*.swatch, "CornerRadius", "6");
        _ = raven.Rwidget_set_attribute(row.*.swatch, "BorderWidth", "1");
        _ = raven.Rwidget_set_attribute(row.*.swatch, "Background", if (value != null and value[0] != 0) value else "transparent");
        _ = raven.Rwidget_add_child(line, row.*.swatch);
    }
    _ = raven.Rwidget_add_child(box, line);
}

fn add_group(title: [*c]const u8, expanded: c_int) raven.Rid {
    const expander: raven.Rid = raven.Rwidget_create(raven.R_WIDGET_EXPANDER);
    const box: raven.Rid = raven.Rwidget_create(raven.R_WIDGET_VBOX);
    raven.Rexpander_set_title(expander, title);
    raven.Rexpander_set_expanded(expander, expanded);
    raven.Rpanel_set_spacing(box, 4.0);
    raven.Rslot_set_padding(box, 4.0, 4.0, 0.0, 6.0);
    _ = raven.Rwidget_add_child(expander, box);
    _ = raven.Rwidget_add_child(g.inspector, expander);
    return box;
}

fn listed(list_: [*c]const u8, name: [*c]const u8) c_int {
    var list = list_;
    while (list.* != 0) {
        const length: usize = libc.strcspn(list, "|");
        if (libc.strlen(name) == length) {
            var item: [96]u8 = undefined;
            _ = libc.snprintf(&item, item.len, "%.*s", @as(c_int, @intCast(length)), list);
            if (same_text(&item, name) != 0) return 1;
        }
        list += length;
        if (list.* == '|') list += 1;
    }
    return 0;
}

fn rebuild_inspector() void {
    const node: raven.Rid = g.selected;
    const title: raven.Rid = raven.Rwidget_find(g.window, "inspector.title");
    const about: raven.Rid = raven.Rwidget_find(g.window, "inspector.about");
    var box: raven.Rid = raven.R_INVALID_ID;
    var group: [*c]const u8 = "";
    var known: [4096]u8 = undefined;
    var count: c_int = undefined;
    var i: c_int = undefined;
    var known_length: c_int = 0;

    g.syncing += 1;
    raven.Rwidget_clear_children(g.inspector);
    g.row_count = 0;
    known[0] = 0;
    if (node == raven.R_INVALID_ID or raven.Rxml_node_is_valid(node) == 0) {
        raven.Rlabel_set_text(title, "Nothing selected");
        raven.Rlabel_set_text(about, "");
        g.syncing -= 1;
        return;
    }
    if (raven.Rxml_node_is_comment(node) != 0) {
        raven.Rlabel_set_text(title, "Comment");
        raven.Rlabel_set_text(about, "Kept in the XML, ignored when the interface is built.");
        add_row(add_group("Comment", raven.R_TRUE), "Text", "#text", raven.R_XML_TEXT, null, raven.Rxml_node_get_text(node), null);
        g.syncing -= 1;
        return;
    }
    const tag: [*c]const u8 = raven.Rxml_node_get_tag(node);
    const special: c_int = special_tag(tag);
    raven.Rlabel_set_text(title, tag);
    raven.Rlabel_set_text(about, if (special >= 0) SPECIAL_TAGS[@intCast(special)].about else if (raven.Rxml_is_widget_registered(tag) != 0) "A tag declared with <Widget>: its own attributes are its parameters." else raven.Rxml_get_tag_description(tag));

    if (special >= 0) {
        var list: [*c]const u8 = SPECIAL_TAGS[@intCast(special)].attributes;
        box = add_group(tag, raven.R_TRUE);
        while (list.* != 0) {
            var name: [72]u8 = undefined;
            const length: usize = libc.strcspn(list, "|");
            _ = libc.snprintf(&name, name.len, "%.*s", @as(c_int, @intCast(length)), list);
            add_row(box, &name, &name, raven.R_XML_TEXT, null, raven.Rxml_node_get_attribute(node, &name), null);
            known_length += libc.snprintf(@as([*c]u8, &known) + @as(usize, @intCast(known_length)), known.len -% @as(usize, @intCast(known_length)), "%s|", @as([*c]const u8, &name));
            list += length;
            if (list.* == '|') list += 1;
        }
    } else {
        count = raven.Rxml_get_attribute_count(tag);
        i = 0;
        while (i < count) : (i += 1) {
            var info: raven.RXmlAttributeInfo = undefined;
            if (raven.Rxml_get_attribute_info(tag, i, &info) == 0) continue;
            if (libc.strcmp(info.group, group) != 0) {
                const own: c_int = @intFromBool(same_text(info.group, tag) != 0 or (libc.strcmp(info.group, "Widget") != 0 and libc.strcmp(info.group, "Slot") != 0 and libc.strcmp(info.group, "Colors") != 0 and libc.strcmp(info.group, "Metrics") != 0));
                group = info.group;
                box = add_group(if (libc.strcmp(group, "Slot") == 0) "Place in the parent" else if (libc.strcmp(group, "Widget") == 0) "Widget" else group, @intFromBool(own != 0 or libc.strcmp(group, "Slot") == 0 or libc.strcmp(group, "Widget") == 0));
            }
            // "Slot.Fill" and "Color.Text" read better without what their group already says
            const label: [*c]const u8 = if (libc.strchr(info.name, '.') != null) libc.strchr(info.name, '.') + 1 else info.name;
            add_row(box, label, info.name, info.type, info.choices, raven.Rxml_node_get_attribute(node, info.name), info.description);
            if (known_length < @as(c_int, known.len) - 80) known_length += libc.snprintf(@as([*c]u8, &known) + @as(usize, @intCast(known_length)), known.len - @as(usize, @intCast(known_length)), "%s|", info.name);
        }
    }
    // the text between the tags, where it means something
    if (raven.Rxml_node_get_text(node)[0] != 0 or raven.Rxml_node_get_child_count(node) == 0) {
        if (raven.Rxml_node_get_text(node)[0] != 0) add_row(add_group("Text inside", raven.R_TRUE), "Text", "#text", raven.R_XML_TEXT, null, raven.Rxml_node_get_text(node), null);
    }
    // what is written on the element and is in no list: other names of an attribute, parameters, mistakes
    box = raven.R_INVALID_ID;
    count = raven.Rxml_node_get_attribute_count(node);
    i = 0;
    while (i < count) : (i += 1) {
        const name: [*c]const u8 = raven.Rxml_node_get_attribute_name(node, i);
        if (listed(&known, name) != 0) continue;
        if (box == raven.R_INVALID_ID) box = add_group(if (special >= 0 and same_text(tag, "Widget") != 0) "Parameters" else "Other attributes", raven.R_TRUE);
        add_row(box, name, name, raven.R_XML_TEXT, null, raven.Rxml_node_get_attribute_value(node, i), null);
    }
    g.syncing -= 1;
}

// ---------------------------------------------------------------------------
//  Selection
// ---------------------------------------------------------------------------

fn update_path_label() void {
    var text: [400]u8 = undefined;
    var caption: [96]u8 = undefined;
    var length: c_int = 0;
    var depth: c_int = 0;
    var i: c_int = undefined;
    var chain: [32]raven.Rid = undefined;
    var walk: raven.Rid = undefined;
    var x: f32 = undefined;
    var y: f32 = undefined;
    var w: f32 = undefined;
    var h: f32 = undefined;
    if (g.selected == raven.R_INVALID_ID or raven.Rxml_node_is_valid(g.selected) == 0) {
        raven.Rlabel_set_text(g.path_label, "");
        return;
    }
    walk = g.selected;
    while (walk != raven.R_INVALID_ID and depth < 32) : (walk = raven.Rxml_node_get_parent(walk)) {
        chain[@intCast(depth)] = walk;
        depth += 1;
    }
    text[0] = 0;
    i = depth - 1;
    while (i >= 0 and length < @as(c_int, text.len) - 80) : (i -= 1) {
        length += libc.snprintf(@as([*c]u8, &text) + @as(usize, @intCast(length)), text.len - @as(usize, @intCast(length)), "%s%s", @as([*c]const u8, if (raven.Rxml_node_is_comment(chain[@intCast(i)]) != 0) "comment" else raven.Rxml_node_get_tag(chain[@intCast(i)])), @as([*c]const u8, if (i > 0) "  >  " else ""));
    }
    walk = raven.Rxml_node_get_widget(g.selected);
    if (walk != raven.R_INVALID_ID and raven.Rwidget_is_valid(walk) != 0) {
        raven.Rwidget_get_rect(walk, &x, &y, &w, &h);
        _ = libc.snprintf(&caption, caption.len, "     %.0f x %.0f", @as(f64, w), @as(f64, h));
        if (length < @as(c_int, text.len) - 40) _ = libc.snprintf(@as([*c]u8, &text) + @as(usize, @intCast(length)), text.len - @as(usize, @intCast(length)), "%s", @as([*c]const u8, &caption));
    }
    raven.Rlabel_set_text(g.path_label, &text);
}

fn select_node(node_: raven.Rid, reveal: c_int) void {
    var node = node_;
    var line: c_int = undefined;
    if (node != raven.R_INVALID_ID and raven.Rxml_node_is_valid(node) == 0) node = raven.R_INVALID_ID;
    g.selected = node;
    g.syncing += 1;
    raven.Rtree_view_set_selected_item(g.tree, if (node != raven.R_INVALID_ID) tree_item_of(raven.R_INVALID_ID, node) else raven.R_INVALID_ID);
    g.syncing -= 1;
    rebuild_inspector();
    update_path_label();
    raven.Rwidget_invalidate(g.outline);
    // the text shows where the element is written
    line = if (node != raven.R_INVALID_ID) raven.Rxml_node_get_line(node) else 0;
    if (line > 0) line += g_iface_offset;
    if (reveal != 0 and line > 0 and g.broken == 0 and raven.Rwidget_is_focused(g.source) == 0) {
        raven.Rtext_editor_set_cursor(g.source, line - 1, 0);
        raven.Rtext_editor_scroll_to_line(g.source, line - 1);
    }
}

// Everything that shows the document, from the document.
fn rebuild_all(keep_inspector: c_int) void {
    rebuild_preview();
    rebuild_tree();
    if (keep_inspector == 0) rebuild_inspector();
    update_path_label();
}

// ---------------------------------------------------------------------------
//  Text -> document
// ---------------------------------------------------------------------------

//
// Reads a text as the document. On a mistake the document stays what it was
// and the mistake is shown; R_FALSE is returned.
//
fn load_text(text: [*c]const u8, record: c_int) c_int {
    var error_: raven.RXmlError = undefined;
    var start: usize = undefined;
    var end: usize = undefined;
    const ui: [*c]u8 = interface_of(text, &start, &end);
    var path: [32]c_int = undefined;
    var depth: c_int = -1;

    if (ui == null) {
        g.broken = raven.R_TRUE;
        g.problem_count = 0;
        g_iface_offset = 0;
        add_problem("The file has no interface element (or one that is not closed): write one, as <Window>...</Window>.", 1, raven.R_TRUE);
        show_problems();
        set_status("No interface in the file: see the Problems tab.");
        return raven.R_FALSE;
    }
    const document: raven.Rid = raven.Rxml_document_parse(ui, libc.strlen(ui), &error_);
    libc.free(ui);
    if (document == raven.R_INVALID_ID) {
        var message: [240]u8 = undefined;
        g.broken = raven.R_TRUE;
        g.problem_count = 0;
        _ = libc.snprintf(&message, message.len, "XML line %d, column %d: %s", error_.line, error_.column, @as([*c]const u8, &error_.message));
        add_problem(&message, error_.line, raven.R_TRUE);
        show_problems();
        set_status("%s", @as([*c]const u8, &message));
        return raven.R_FALSE;
    }
    if (g.document != raven.R_INVALID_ID) {
        if (g.selected != raven.R_INVALID_ID and raven.Rxml_node_is_valid(g.selected) != 0) depth = node_path(g.selected, &path, 32);
        raven.Rxml_document_destroy(g.document);
    }
    g.document = document;
    g.broken = raven.R_FALSE;
    g.selected = if (depth >= 0) node_at_path(&path, depth) else raven.Rxml_document_get_root(document);
    g.hovered = raven.R_INVALID_ID;
    if (record != 0) history_push(text, @intFromBool(record == 2));
    rebuild_all(raven.R_FALSE);
    if (g.problem_count == 0) {
        set_status("Ready.");
    } else {
        set_status("%d problem%s in the document: see the Problems tab.", g.problem_count, @as([*c]const u8, if (g.problem_count > 1) "s" else ""));
    }
    return raven.R_TRUE;
}

// Replaces everything: a new file, a file opened, a step of history.
fn set_document_text(text: [*c]const u8, record: c_int) c_int {
    g.syncing += 1;
    raven.Rtext_editor_set_text(g.source, text);
    g.syncing -= 1;
    return load_text(text, record);
}

fn on_parse_timer(timer: raven.Rid, user_data: ?*anyopaque) callconv(.c) void {
    _ = timer;
    _ = user_data;
    g.parse_timer = raven.R_INVALID_ID;
    if (load_text(raven.Rtext_editor_get_text(g.source), 2) != 0) {
        g.modified = raven.R_TRUE;
        update_title();
    }
}

fn on_source_changed(editor: raven.Rid, user_data: ?*anyopaque) callconv(.c) void {
    _ = editor;
    _ = user_data;
    if (g.syncing != 0) return;
    // read once the typing pauses: half-written tags are not worth reporting
    if (g.parse_timer != raven.R_INVALID_ID and raven.Rtimer_is_valid(g.parse_timer) != 0) raven.Rtimer_destroy(g.parse_timer);
    g.parse_timer = raven.Rtimer_create(0.30, raven.R_FALSE, &on_parse_timer, null);
    g.modified = raven.R_TRUE;
    update_title();
}

// The text of the editor was not read yet (the user is typing): read it now, before acting on the document.
fn flush_source() c_int {
    if (g.parse_timer != raven.R_INVALID_ID and raven.Rtimer_is_valid(g.parse_timer) != 0) {
        raven.Rtimer_destroy(g.parse_timer);
        g.parse_timer = raven.R_INVALID_ID;
        _ = load_text(raven.Rtext_editor_get_text(g.source), 2);
    }
    if (g.broken != 0) {
        set_status("The XML has a mistake: fix it first (see the Problems tab).");
        return raven.R_FALSE;
    }
    return raven.R_TRUE;
}

// ---------------------------------------------------------------------------
//  Palette
// ---------------------------------------------------------------------------

fn palette_fill() void {
    const filter: [*c]const u8 = raven.Rtext_input_get_text(g.palette_filter);
    var i: c_int = undefined;
    const total: c_int = raven.Rxml_get_tag_count() + raven.Rxml_get_registered_widget_count() + 2;
    const extra = [_][*c]const u8{ "Item", "Shortcut" };

    i = 0;
    while (i < g.palette_count) : (i += 1) libc.free(g.palette_tags[@intCast(i)]);
    libc.free(@ptrCast(g.palette_tags));
    g.palette_tags = @ptrCast(@alignCast(libc.calloc(@intCast(total), @sizeOf([*c]u8))));
    g.palette_count = 0;
    g.syncing += 1;
    raven.Rlist_view_clear_items(g.palette);
    // the tags the document declares come first: they are what this interface is made of
    i = 0;
    while (i < raven.Rxml_get_registered_widget_count()) : (i += 1) {
        const name: [*c]const u8 = raven.Rxml_get_registered_widget_name(i);
        if (name == null or contains_text(name, filter) == 0 or same_text(name, "ToolButton") != 0) continue;
        g.palette_tags[@intCast(g.palette_count)] = copy_text(name);
        g.palette_count += 1;
        _ = raven.Rlist_view_add_item(g.palette, name);
    }
    i = 1;
    while (i < raven.Rxml_get_tag_count()) : (i += 1) {
        const name: [*c]const u8 = raven.Rxml_get_tag_name(i);
        if (contains_text(name, filter) == 0) continue;
        g.palette_tags[@intCast(g.palette_count)] = copy_text(name);
        g.palette_count += 1;
        _ = raven.Rlist_view_add_item(g.palette, name);
    }
    i = 0;
    while (i < 2) : (i += 1) {
        if (contains_text(extra[@intCast(i)], filter) == 0) continue;
        g.palette_tags[@intCast(g.palette_count)] = copy_text(extra[@intCast(i)]);
        g.palette_count += 1;
        _ = raven.Rlist_view_add_item(g.palette, extra[@intCast(i)]);
    }
    g.syncing -= 1;
}

// Adds a piece of XML inside the selection, or after it when it cannot contain anything.
fn insert_xml(xml: [*c]const u8) void {
    var target: raven.Rid = g.selected;
    var index: c_int = -1;
    if (g.has_document == 0) {
        set_status("Open an interface first (Ctrl+Space: the content drawer, or File > New).");
        return;
    }
    if (flush_source() == 0) return;
    if (target == raven.R_INVALID_ID or raven.Rxml_node_is_valid(target) == 0) target = raven.Rxml_document_get_root(g.document);
    if (raven.Rxml_node_is_comment(target) != 0 or (special_tag(raven.Rxml_node_get_tag(target)) < 0 and raven.Rxml_get_tag_children(raven.Rxml_node_get_tag(target)) == 0)) {
        const parent: raven.Rid = raven.Rxml_node_get_parent(target);
        if (parent == raven.R_INVALID_ID) {
            set_status("<%s> cannot contain anything.", raven.Rxml_node_get_tag(target));
            return;
        }
        index = raven.Rxml_node_get_index(target) + 1;
        target = parent;
    }
    const added: raven.Rid = raven.Rxml_node_add_xml(target, xml, libc.strlen(xml), index);
    if (added == raven.R_INVALID_ID) {
        set_status("This is not XML that can be added.");
        return;
    }
    g.selected = added;
    document_changed(raven.R_FALSE);
    select_node(added, raven.R_TRUE);
    set_status("Added <%s> to <%s>.", raven.Rxml_node_get_tag(added), raven.Rxml_node_get_tag(target));
}

fn action_palette_add(sender: raven.Rid, action: [*c]const u8, user_data: ?*anyopaque) callconv(.c) void {
    const index: c_int = raven.Rlist_view_get_selected(g.palette);
    var i: c_int = undefined;
    var xml: [160]u8 = undefined;
    _ = sender;
    _ = action;
    _ = user_data;
    if (index < 0 or index >= g.palette_count) {
        set_status("Choose a widget in the list first.");
        return;
    }
    const tag: [*c]const u8 = g.palette_tags[@intCast(index)];
    i = 0;
    while (i < @as(c_int, TEMPLATES.len)) : (i += 1) {
        if (same_text(TEMPLATES[@intCast(i)].tag, tag) != 0) {
            insert_xml(TEMPLATES[@intCast(i)].xml);
            return;
        }
    }
    _ = libc.snprintf(&xml, xml.len, "<%s/>", tag);
    insert_xml(&xml);
}

fn action_palette_filter(sender: raven.Rid, action: [*c]const u8, user_data: ?*anyopaque) callconv(.c) void {
    _ = sender;
    _ = action;
    _ = user_data;
    if (g.syncing == 0) palette_fill();
}

// ---------------------------------------------------------------------------
//  Editing the tree
// ---------------------------------------------------------------------------

// The element the commands of the Edit menu act on, or R_INVALID_ID with a word in the status bar.
fn edit_target(needs_parent: c_int) raven.Rid {
    const focus: raven.Rid = raven.Rwindow_get_focused_widget(g.window);
    // (a key that also edits text, pressed in an input, was for the input)
    if (focus != raven.R_INVALID_ID and (raven.Rwidget_get_type(focus) == raven.R_WIDGET_TEXT_INPUT or raven.Rwidget_get_type(focus) == raven.R_WIDGET_TEXT_EDITOR) and focus != g.palette_filter) {
        return raven.R_INVALID_ID;
    }
    if (g.has_document == 0) {
        set_status("No interface is open.");
        return raven.R_INVALID_ID;
    }
    if (flush_source() == 0) return raven.R_INVALID_ID;
    if (g.selected == raven.R_INVALID_ID or raven.Rxml_node_is_valid(g.selected) == 0) {
        set_status("Nothing is selected.");
        return raven.R_INVALID_ID;
    }
    if (needs_parent != 0 and raven.Rxml_node_get_parent(g.selected) == raven.R_INVALID_ID) {
        set_status("This cannot be done to the root of the document.");
        return raven.R_INVALID_ID;
    }
    return g.selected;
}

fn action_edit(sender: raven.Rid, action: [*c]const u8, user_data: ?*anyopaque) callconv(.c) void {
    const what: [*c]const u8 = action + 5;
    var node: raven.Rid = undefined;
    var parent: raven.Rid = undefined;
    var index: c_int = undefined;
    _ = sender;
    _ = user_data;

    if (libc.strcmp(what, "copy") == 0) {
        node = edit_target(raven.R_FALSE);
        if (node == raven.R_INVALID_ID) return;
        raven.Rclipboard_set_text(raven.Rxml_node_to_string(node));
        set_status("Copied <%s> as XML.", raven.Rxml_node_get_tag(node));
        return;
    }
    if (libc.strcmp(what, "paste") == 0) {
        const text: [*c]const u8 = raven.Rclipboard_get_text();
        if (text != null and text[0] != 0) insert_xml(text) else set_status("The clipboard is empty.");
        return;
    }
    node = edit_target(raven.R_TRUE);
    if (node == raven.R_INVALID_ID) return;
    parent = raven.Rxml_node_get_parent(node);
    index = raven.Rxml_node_get_index(node);

    if (libc.strcmp(what, "delete") == 0) {
        var next: raven.Rid = raven.Rxml_node_get_child(parent, index + 1);
        if (next == raven.R_INVALID_ID) next = if (index > 0) raven.Rxml_node_get_child(parent, index - 1) else parent;
        raven.Rxml_node_remove(node);
        g.selected = next;
        set_status("Deleted.");
    } else if (libc.strcmp(what, "duplicate") == 0) {
        g.selected = raven.Rxml_node_duplicate(node);
        set_status("Duplicated.");
    } else if (libc.strcmp(what, "up") == 0) {
        if (index == 0) return;
        _ = raven.Rxml_node_move(node, parent, index - 1);
    } else if (libc.strcmp(what, "down") == 0) {
        if (index + 1 >= raven.Rxml_node_get_child_count(parent)) return;
        _ = raven.Rxml_node_move(node, parent, index + 1);
    } else if (libc.strcmp(what, "out") == 0) {
        const grand: raven.Rid = raven.Rxml_node_get_parent(parent);
        if (grand == raven.R_INVALID_ID) {
            set_status("It is already at the top.");
            return;
        }
        _ = raven.Rxml_node_move(node, grand, raven.Rxml_node_get_index(parent) + 1);
    } else if (libc.strcmp(what, "in") == 0) {
        const previous: raven.Rid = if (index > 0) raven.Rxml_node_get_child(parent, index - 1) else raven.R_INVALID_ID;
        if (previous == raven.R_INVALID_ID or raven.Rxml_node_is_comment(previous) != 0) {
            set_status("There is no element before it to move into.");
            return;
        }
        _ = raven.Rxml_node_move(node, previous, -1);
    } else if (libc.strncmp(what, "wrap.", 5) == 0) {
        const wrapper: raven.Rid = raven.Rxml_node_add_child(parent, what + 5, index);
        if (wrapper == raven.R_INVALID_ID) return;
        _ = raven.Rxml_node_move(node, wrapper, -1);
        // its place in the parent goes to what now holds it
        {
            const slot = [_][*c]const u8{ "Slot.Fill", "Slot.HAlign", "Slot.VAlign", "Slot.Padding", "Slot.Title", "Slot.Column", "Slot.Row", "Slot.Dock" };
            var i: c_int = 0;
            while (i < @as(c_int, slot.len)) : (i += 1) {
                const value: [*c]const u8 = raven.Rxml_node_get_attribute(node, slot[@intCast(i)]);
                if (value == null) continue;
                raven.Rxml_node_set_attribute(wrapper, slot[@intCast(i)], value);
                raven.Rxml_node_set_attribute(node, slot[@intCast(i)], null);
            }
        }
        g.selected = wrapper;
        set_status("Wrapped in <%s>.", what + 5);
    } else if (libc.strcmp(what, "unwrap") == 0) {
        const count: c_int = raven.Rxml_node_get_child_count(node);
        var i: c_int = undefined;
        if (count == 0) {
            set_status("<%s> contains nothing to keep.", raven.Rxml_node_get_tag(node));
            return;
        }
        g.selected = raven.Rxml_node_get_child(node, 0);
        i = 0;
        while (i < count) : (i += 1) _ = raven.Rxml_node_move(raven.Rxml_node_get_child(node, 0), parent, index + i);
        raven.Rxml_node_remove(node);
        set_status("Unwrapped.");
    } else {
        return;
    }
    document_changed(raven.R_FALSE);
    select_node(g.selected, raven.R_TRUE);
}

fn action_history(sender: raven.Rid, action: [*c]const u8, user_data: ?*anyopaque) callconv(.c) void {
    const step: c_int = if (libc.strcmp(action, "edit.undo") == 0) -1 else 1;
    const focus: raven.Rid = raven.Rwindow_get_focused_widget(g.window);
    _ = sender;
    _ = user_data;
    // in a text, Ctrl+Z is for the text
    if (focus != raven.R_INVALID_ID and (raven.Rwidget_get_type(focus) == raven.R_WIDGET_TEXT_INPUT or raven.Rwidget_get_type(focus) == raven.R_WIDGET_TEXT_EDITOR)) return;
    if (g.has_document == 0) return;
    if (flush_source() == 0 and step > 0) return;
    if (g.history_at + step < 0 or g.history_at + step >= g.history_count) {
        set_status(if (step < 0) "Nothing to undo." else "Nothing to redo.");
        return;
    }
    g.history_at += step;
    g.history_typed_at = 0.0;
    _ = set_document_text(g.history[@intCast(g.history_at)], raven.R_FALSE);
    g.modified = raven.R_TRUE;
    update_title();
    set_status(if (step < 0) "Undone." else "Redone.");
}

// ---------------------------------------------------------------------------
//  Files
// ---------------------------------------------------------------------------

// Save, don't save, or cancel: what the user wants before `why` ("closing the project"...).
export fn ide_confirm_unsaved(why: [*c]const u8) c_int {
    var text: [400]u8 = undefined;
    var answer: raven.RMessageResult = undefined;
    const interface: c_int = @intFromBool(g.has_document != 0 and g.modified != 0);
    if (g.quitting != 0) return raven.R_TRUE;
    if (interface == 0 and ide.editors_any_modified() == 0 and ide.strings_any_modified() == 0) return raven.R_TRUE;
    _ = libc.snprintf(&text, text.len, "Some files have changes that were not saved. Save them before %s?", why);
    answer = raven.Rmessage_box(g.window, "Unsaved changes", &text, raven.R_MESSAGE_YES_NO_CANCEL);
    if (answer == raven.R_MESSAGE_RESULT_CANCEL) return raven.R_FALSE;
    if (answer == raven.R_MESSAGE_RESULT_NO) {
        g.modified = raven.R_FALSE;
        return raven.R_TRUE;
    }
    // (an interface never saved asks where; refusing there cancels)
    if (interface != 0 and save_file(@intFromBool(g.path == null and g_is_xmlc == 0)) == 0) return raven.R_FALSE;
    if (ide.editors_any_modified() != 0 and ide.editors_save_all() == 0) return raven.R_FALSE;
    if (ide.strings_any_modified() != 0 and ide.strings_save() == 0) return raven.R_FALSE;
    return raven.R_TRUE;
}

fn confirm_discard() c_int {
    return ide_confirm_unsaved("closing");
}

//
// The panels of the visual editor are only there while it shows an interface
// (the Preview of the content drawer, File > New...): the code editors have
// the room the rest of the time. Hidden in this order, they come back in the
// other one, each where it was.
//
const VISUAL_PANELS = [_][*c]const u8{ "source", "problems", "panel.properties", "panel.tree", "panel.widgets", "panel.preview" };
const VISUAL_PANEL_COUNT: c_int = @intCast(VISUAL_PANELS.len);

fn show_visual_panels(shown: c_int, force: c_int) void {
    const S = struct {
        var now: c_int = -1;
    };
    var i: c_int = undefined;
    if (S.now == shown and force == 0) return;
    S.now = shown;
    if (shown == 0) {
        i = 0;
        while (i < VISUAL_PANEL_COUNT) : (i += 1) raven.Rdock_area_hide_panel(g.dock, raven.Rwidget_find(g.window, VISUAL_PANELS[@intCast(i)]));
        return;
    }
    i = VISUAL_PANEL_COUNT - 1;
    while (i >= 0) : (i -= 1) {
        const panel: raven.Rid = raven.Rwidget_find(g.window, VISUAL_PANELS[@intCast(i)]);
        raven.Rdock_area_open_panel(g.dock, panel);
        // the preview goes with the code editors, in their tabs (where it was before they came)
        if (panel == g_ide_center) {
            const editor: raven.Rid = ide.editors_anchor();
            if (editor != raven.R_INVALID_ID and editor != g_ide_center) {
                raven.Rdock_area_move_panel(g.dock, panel, raven.R_DOCK_TAB, editor, 0.0);
                raven.Rdock_area_show_panel(g.dock, panel);
            }
        }
    }
    raven.Rdock_area_show_panel(g.dock, g_ide_center);
}

fn show_document(shown: c_int) void {
    g.has_document = shown;
    show_visual_panels(shown, raven.R_FALSE);
    raven.Rwidget_set_visibility(g.frame, if (shown != 0) raven.R_VISIBLE else raven.R_COLLAPSED);
    raven.Rwidget_set_visibility(g.outline, if (shown != 0) raven.R_VISIBLE else raven.R_COLLAPSED);
    raven.Rwidget_set_visibility(raven.Rwidget_find(g.window, "stage.empty"), if (shown != 0) raven.R_COLLAPSED else raven.R_VISIBLE);
    raven.Rtext_editor_set_read_only(g.source, @intFromBool(shown == 0));
}

fn new_document(text: [*c]const u8, path: [*c]const u8) void {
    libc.free(g.path);
    g.path = if (path != null) copy_text(path) else null;
    show_document(raven.R_TRUE);
    ide.welcome_hide();
    history_clear();
    if (g.document != raven.R_INVALID_ID) raven.Rxml_document_destroy(g.document);
    g.document = raven.R_INVALID_ID;
    g.selected = raven.R_INVALID_ID;
    if (set_document_text(text, raven.R_TRUE) == 0) {
        // a file that is not XML: an empty document to stand on, the text left to be fixed
        g.document = raven.Rxml_document_create("VBox");
        g.selected = raven.Rxml_document_get_root(g.document);
        rebuild_all(raven.R_FALSE);
        g.broken = raven.R_TRUE;
    }
    g.modified = raven.R_FALSE;
    update_title();
    palette_fill();
}

// the paths written in a file (images, fonts, includes) start from its folder
fn base_path_of(path: [*c]const u8) void {
    const folder: [*c]u8 = copy_text(path);
    var slash: [*c]u8 = libc.strrchr(folder, '/');
    const backslash: [*c]u8 = libc.strrchr(folder, '\\');
    if (backslash != null and (slash == null or backslash > slash)) slash = backslash;
    if (slash != null) {
        slash.* = 0;
        raven.Rxml_set_base_path(folder);
    }
    libc.free(folder);
}

fn open_file(path: [*c]const u8) void {
    var size: usize = 0;
    const text: [*c]u8 = raven.Rfile_read(path, &size);
    if (text == null) {
        set_status("Cannot read %s", path);
        return;
    }
    base_path_of(path);
    g_is_xmlc = 0;
    g_iface_offset = 0;
    raven.Rdock_area_set_panel_title(g.dock, g.source, "XML");
    raven.Rtext_editor_set_language(g.source, "XML");
    new_document(text, path);
    raven.Rmemory_free(text);
    if (g.broken == 0) set_status("Opened %s", path);
}

fn save_file(ask: c_int) c_int {
    const filters = [_]raven.RFileFilter{ .{ .name = "XML", .patterns = "*.xml" }, .{ .name = "All files", .patterns = "*" } };
    if (g.has_document == 0) return raven.R_TRUE;
    // an .xmlc is written with its scripts
    if (g_is_xmlc != 0 and ask == 0) {
        const ok: c_int = ide.xmlc_save();
        if (ok != 0) {
            g.modified = raven.R_FALSE;
            update_title();
        }
        return ok;
    }
    if (ask != 0 or g.path == null) {
        var desc: raven.RFileDialogDesc = undefined;
        var chosen: [*c]const u8 = undefined;
        desc = std.mem.zeroes(raven.RFileDialogDesc);
        desc.parent = g.window;
        desc.title = "Save the interface";
        desc.file_name = "interface.xml";
        desc.filters = &filters;
        desc.filter_count = 2;
        desc.default_extension = "xml";
        chosen = raven.Rfile_dialog_save(&desc);
        if (chosen == null) return raven.R_FALSE;
        chosen = copy_text(chosen);
        libc.free(g.path);
        g.path = @constCast(chosen);
        // saved as a plain .xml: the interface alone, the scripts stay in the .xmlc
        if (g_is_xmlc != 0) {
            var start: usize = undefined;
            var end: usize = undefined;
            const ui: [*c]u8 = interface_of(raven.Rtext_editor_get_text(g.source), &start, &end);
            ide.xmlc_close();
            g_is_xmlc = 0;
            g_iface_offset = 0;
            if (ui != null) {
                g.syncing += 1;
                raven.Rtext_editor_set_text(g.source, ui);
                g.syncing -= 1;
                libc.free(ui);
            }
            raven.Rdock_area_set_panel_title(g.dock, g.source, "XML");
            raven.Rtext_editor_set_language(g.source, "XML");
        }
    }
    // what is saved is the text as it is written, mistakes included: nothing typed is lost
    const text: [*c]const u8 = raven.Rtext_editor_get_text(g.source);
    if (raven.Rfile_write(g.path, text, libc.strlen(text)) == 0) {
        set_status("Cannot write %s", g.path);
        return raven.R_FALSE;
    }
    g.modified = raven.R_FALSE;
    update_title();
    set_status("Saved %s", g.path);
    return raven.R_TRUE;
}

fn action_file(sender: raven.Rid, action: [*c]const u8, user_data: ?*anyopaque) callconv(.c) void {
    const filters = [_]raven.RFileFilter{
        .{ .name = "Interfaces", .patterns = "*.xml;*.xmlc;*.xmlc++;*.xmlcpp;*.xmlrs;*.xmlpy;*.xmlgo;*.xmlcs;*.xmlzig;*.xmllua" },
        .{ .name = "XML", .patterns = "*.xml" },
        .{ .name = "XML with code", .patterns = "*.xmlc;*.xmlc++;*.xmlcpp;*.xmlrs;*.xmlpy;*.xmlgo;*.xmlcs;*.xmlzig;*.xmllua" },
        .{ .name = "All files", .patterns = "*" },
    };
    _ = sender;
    _ = user_data;
    if (libc.strncmp(action, "file.new.", 9) == 0) {
        const kind: [*c]const u8 = action + 9;
        if (confirm_discard() == 0) return;
        if (g_is_xmlc != 0) {
            ide.xmlc_close();
            g_is_xmlc = 0;
            g_iface_offset = 0;
        }
        new_document(if (libc.strcmp(kind, "panel") == 0) TEMPLATE_PANEL else if (libc.strcmp(kind, "form") == 0) TEMPLATE_FORM else TEMPLATE_WINDOW, null);
        set_status("New document: File > Save writes it.");
    } else if (libc.strcmp(action, "file.welcome") == 0) {
        ide.welcome_show();
        update_title();
    } else if (libc.strcmp(action, "file.open") == 0) {
        var desc: raven.RFileDialogDesc = undefined;
        var chosen: [*c]const u8 = undefined;
        if (g.has_document != 0 and g.modified != 0 and ide_confirm_unsaved("opening another file") == 0) return;
        desc = std.mem.zeroes(raven.RFileDialogDesc);
        desc.parent = g.window;
        desc.title = "Open an interface";
        desc.filters = &filters;
        desc.filter_count = 4;
        chosen = raven.Rfile_dialog_open(&desc);
        if (chosen != null) {
            const path: [*c]u8 = copy_text(chosen);
            g.modified = raven.R_FALSE;
            ide.ide_open_file(path, 0);
            libc.free(path);
        }
    } else if (libc.strcmp(action, "file.save") == 0) {
        // the code editor the keyboard is in, else the interface
        if (ide.editors_save_focused() < 0) _ = save_file(raven.R_FALSE);
    } else if (libc.strcmp(action, "file.save_as") == 0) {
        _ = save_file(raven.R_TRUE);
    } else if (libc.strcmp(action, "file.save_all") == 0) {
        if (g.modified != 0 and (g.path != null or g_is_xmlc != 0)) _ = save_file(raven.R_FALSE);
        _ = ide.editors_save_all();
        _ = ide.strings_save();
        set_status("Everything is saved.");
    } else if (libc.strcmp(action, "file.quit") == 0) {
        if (confirm_discard() != 0) raven.Rquit(0);
    }
}

fn on_close(window: raven.Rid, user_data: ?*anyopaque) callconv(.c) c_int {
    _ = window;
    _ = user_data;
    if (confirm_discard() == 0) return raven.R_FALSE;
    raven.Rquit(0);
    return raven.R_TRUE;
}

fn on_drop(target: raven.Rid, event: [*c]const raven.RDropEvent, user_data: ?*anyopaque) callconv(.c) c_int {
    _ = target;
    _ = user_data;
    // a folder dropped on the window is a project; files are opened; a text is added as XML
    if (event.*.phase != raven.R_DROP_DROPPED) return raven.R_TRUE;
    if (event.*.path_count > 0) {
        if (ide.ide_is_dir(event.*.paths[0]) != 0) {
            _ = ide.project_open(event.*.paths[0]);
        } else {
            ide.ide_open_file(event.*.paths[0], 0);
        }
    } else if (event.*.text != null and event.*.text[0] != 0) {
        insert_xml(event.*.text);
    }
    return raven.R_TRUE;
}

// ---------------------------------------------------------------------------
//  What the rest of the IDE asks the visual editor (ide.h)
// ---------------------------------------------------------------------------

export fn designer_load_interface(text: [*c]const u8, path: [*c]const u8, is_xmlc: c_int) void {
    if (path != null) base_path_of(path);
    g_is_xmlc = is_xmlc;
    // (the panel says that it holds the interface part of the file)
    raven.Rdock_area_set_panel_title(g.dock, g.source, if (is_xmlc != 0 and path != null) ide.ide_basename(path) else "XML");
    // an .xmlc: its code colored in the language of the file (XMLC, XMLRS, XMLPY... of the text editor)
    raven.Rtext_editor_set_language(g.source, if (is_xmlc != 0 and path != null and raven.Rlanguage_for_file(path) != null) raven.Rlanguage_for_file(path) else "XML");
    new_document(text, path);
    if (g.broken == 0 and path != null) set_status("Opened %s", path);
}

export fn designer_open_file(path: [*c]const u8) void {
    open_file(path);
}

export fn designer_update_title() void {
    update_title();
}

export fn designer_get_interface_text() [*c]const u8 {
    return raven.Rtext_editor_get_text(g.source);
}

export fn designer_get_path() [*c]const u8 {
    return g.path;
}

export fn designer_is_modified() c_int {
    return g.modified;
}

export fn designer_set_modified(modified: c_int) void {
    g.modified = modified;
    update_title();
}

export fn designer_save() c_int {
    if (g.has_document == 0) return raven.R_TRUE;
    if (g.path == null and g_is_xmlc == 0) return save_file(raven.R_TRUE);
    return save_file(raven.R_FALSE);
}

export fn designer_problem_count() c_int {
    return g.problem_count;
}

export fn designer_has_document() c_int {
    return g.has_document;
}

export fn designer_close() void {
    if (g.parse_timer != raven.R_INVALID_ID and raven.Rtimer_is_valid(g.parse_timer) != 0) raven.Rtimer_destroy(g.parse_timer);
    g.parse_timer = raven.R_INVALID_ID;
    if (ide.xmlc_is_open() != 0) ide.xmlc_close();
    g_is_xmlc = 0;
    g_iface_offset = 0;
    libc.free(g.path);
    g.path = null;
    history_clear();
    if (g.preview != raven.R_INVALID_ID and raven.Rwidget_is_valid(g.preview) != 0) raven.Rwidget_destroy(g.preview);
    g.preview = raven.R_INVALID_ID;
    if (g.document != raven.R_INVALID_ID) raven.Rxml_document_destroy(g.document);
    // (an empty document stands behind, so that nothing has to check for none)
    g.document = raven.Rxml_document_create("VBox");
    g.selected = raven.R_INVALID_ID;
    g.hovered = raven.R_INVALID_ID;
    g.broken = raven.R_FALSE;
    g.modified = raven.R_FALSE;
    g.syncing += 1;
    raven.Rtext_editor_set_text(g.source, "");
    raven.Rtree_view_clear_items(g.tree);
    g.syncing -= 1;
    g.problem_count = 0;
    show_problems();
    rebuild_inspector();
    raven.Rlabel_set_text(raven.Rwidget_find(g.window, "stage.size"), "");
    raven.Rlabel_set_text(g.path_label, "");
    raven.Rdock_area_set_panel_title(g.dock, g.source, "XML");
    raven.Rtext_editor_set_language(g.source, "XML");
    show_document(raven.R_FALSE);
    update_title();
}

export fn designer_add_marker(line: c_int, column: c_int, error_: c_int, message: [*c]const u8) void {
    if (line <= 0) return;
    raven.Rtext_editor_add_marker(g.source, line - 1, if (column > 0) column - 1 else 0, -1, if (error_ != 0) raven.R_MARKER_ERROR else raven.R_MARKER_WARNING, message);
}

export fn designer_go_to_line(line: c_int) void {
    if (line <= 0) return;
    raven.Rdock_area_open_panel(g.dock, g.source);
    raven.Rtext_editor_set_cursor(g.source, line - 1, 0);
    raven.Rtext_editor_scroll_to_line(g.source, line - 1);
    raven.Rwidget_focus(g.source);
}

fn collect_names(node: raven.Rid, names: [*c][*c]const u8, max: c_int, count: [*c]c_int) void {
    var i: c_int = undefined;
    if (node == raven.R_INVALID_ID or raven.Rxml_node_is_comment(node) != 0) return;
    // the body of a <Widget> declaration is a template
    if (same_text(raven.Rxml_node_get_tag(node), "Widget") != 0) return;
    const name: [*c]const u8 = raven.Rxml_node_get_attribute(node, "Name");
    if (name != null and count.* < max) {
        var p: [*c]const u8 = undefined;
        var valid: c_int = @intFromBool((name[0] >= 'a' and name[0] <= 'z') or (name[0] >= 'A' and name[0] <= 'Z') or name[0] == '_');
        p = name;
        while (p.* != 0 and valid != 0) : (p += 1) valid = @intFromBool((p.* >= 'a' and p.* <= 'z') or (p.* >= 'A' and p.* <= 'Z') or (p.* >= '0' and p.* <= '9') or p.* == '_');
        if (valid != 0) {
            i = 0;
            while (i < count.*) : (i += 1) {
                if (libc.strcmp(names[@intCast(i)], name) == 0) valid = 0;
            }
            if (valid != 0) {
                names[@intCast(count.*)] = name;
                count.* += 1;
            }
        }
    }
    const n: c_int = raven.Rxml_node_get_child_count(node);
    i = 0;
    while (i < n) : (i += 1) collect_names(raven.Rxml_node_get_child(node, i), names, max, count);
}

export fn designer_get_names(names: [*c][*c]const u8, max: c_int) c_int {
    var count: c_int = 0;
    if (g.document != raven.R_INVALID_ID) collect_names(raven.Rxml_document_get_root(g.document), names, max, &count);
    return count;
}

export fn designer_refresh_preview() void {
    ide.island_preview_changed();
    if (g.document != raven.R_INVALID_ID and g.broken == 0) rebuild_preview();
}

export fn designer_get_frame() raven.Rid {
    return g.frame;
}

// ---------------------------------------------------------------------------
//  View
// ---------------------------------------------------------------------------

fn set_interact(interact: c_int) void {
    g.interact = interact;
    // the frame of the selection stays, but lets the pointer through to the interface
    raven.Rwidget_set_hit_testable(g.outline, @intFromBool(interact == 0));
    g.syncing += 1;
    raven.Rcheckbox_set_checked(g.interact_switch, interact);
    raven.Rmenu_item_set_checked(raven.Rwidget_find(g.window, "menu.interact"), interact);
    g.syncing -= 1;
    g.hovered = raven.R_INVALID_ID;
    raven.Rwidget_invalidate(g.outline);
    set_status(if (interact != 0) "The preview reacts as the interface will." else "A click in the preview selects an element.");
}

fn action_view(sender: raven.Rid, action: [*c]const u8, user_data: ?*anyopaque) callconv(.c) void {
    const themes = [_]struct { name: [*c]const u8, theme: raven.RTheme }{
        .{ .name = "dark", .theme = raven.R_THEME_DARK },
        .{ .name = "light", .theme = raven.R_THEME_LIGHT },
        .{ .name = "glass_dark", .theme = raven.R_THEME_GLASS_DARK },
        .{ .name = "glass_light", .theme = raven.R_THEME_GLASS_LIGHT },
    };
    _ = user_data;
    if (libc.strncmp(action, "view.theme.", 11) == 0) {
        var i: c_int = 0;
        while (i < 4) : (i += 1) {
            var name: [40]u8 = undefined;
            _ = libc.snprintf(&name, name.len, "theme.%s", themes[@intCast(i)].name);
            raven.Rmenu_item_set_checked(raven.Rwidget_find(g.window, &name), @intFromBool(libc.strcmp(themes[@intCast(i)].name, action + 11) == 0));
            if (libc.strcmp(themes[@intCast(i)].name, action + 11) == 0) {
                raven.Rtheme_apply(themes[@intCast(i)].theme);
                // (the next start comes back to it)
                if (g.quitting == 0) ide.prefs_set("theme", themes[@intCast(i)].name);
            }
        }
    } else if (libc.strcmp(action, "view.interact") == 0) {
        set_interact(@intFromBool(g.interact == 0));
    } else if (libc.strcmp(action, "view.interact.switch") == 0) {
        if (g.syncing == 0) set_interact(raven.Rcheckbox_is_checked(sender));
    } else if (libc.strcmp(action, "view.run") == 0) {
        if (g.has_document == 0) {
            set_status("No interface is open: nothing to show in a window.");
            return;
        }
        if (flush_source() == 0) return;
        if (g.run_window != raven.R_INVALID_ID and raven.Rwindow_is_valid(g.run_window) != 0) raven.Rwindow_destroy(g.run_window);
        g.collecting = raven.R_TRUE;
        if (same_text(raven.Rxml_node_get_tag(raven.Rxml_document_get_root(g.document)), "Window") != 0) {
            g.run_window = raven.Rxml_document_create_window(g.document);
        } else {
            // a piece of interface: a window around it
            const content: raven.Rid = raven.Rxml_document_create_widget(g.document);
            g.run_window = if (content != raven.R_INVALID_ID) raven.Rwindow_create("Preview", 640, 480, raven.R_WINDOW_DEFAULT) else raven.R_INVALID_ID;
            if (g.run_window != raven.R_INVALID_ID) raven.Rwindow_set_content(g.run_window, content);
        }
        g.collecting = raven.R_FALSE;
        // (the widgets of the preview are what the nodes lead to, not those of this window)
        rebuild_preview();
        set_status(if (g.run_window != raven.R_INVALID_ID) "Running in its own window." else "The interface could not be built: see the Problems tab.");
    } else if (libc.strcmp(action, "view.reset") == 0) {
        _ = raven.Rdock_area_load_layout(g.dock, @ptrCast(raven.Rwidget_get_user_handle(g.dock)));
        // (the code editors are not in the layout: they go back together, with the preview)
        ide.editors_regroup();
        // (the layout names the panels of the visual editor: without an interface they go again)
        if (g.has_document == 0) show_visual_panels(raven.R_FALSE, raven.R_TRUE);
    } else if (libc.strcmp(action, "view.preview") == 0) {
        // the interface of the code editor in front
        const path: [*c]const u8 = ide.editors_current_path();
        if (path != null and (ide.ide_interface_language(path) != null or ide.ide_iequal(ide.ide_extension(path), "xml") != 0)) {
            const copy: [*c]u8 = copy_text(path);
            ide.ide_preview_file(copy);
            libc.free(copy);
        } else if (g.has_document != 0) {
            raven.Rdock_area_open_panel(g.dock, g_ide_center);
        } else {
            set_status("The file in front is not an interface (.xml, .xmlc, .xmlrs...): nothing to preview.");
        }
    } else if (libc.strcmp(action, "view.preview.close") == 0) {
        _ = designer_close_preview();
    } else if (libc.strcmp(action, "view.zoom.reset") == 0) {
        ide.editors_reset_zoom();
    }
}

// The preview closes: the file goes back to a code editor, its unsaved changes with it.
export fn designer_close_preview() c_int {
    var modified: c_int = g.modified;
    if (g.has_document == 0) return raven.R_TRUE;
    if (g.path == null) {
        // a document never saved has no code editor to go to: saved, or dropped
        const answer: raven.RMessageResult = if (g.modified != 0) raven.Rmessage_box(g.window, "Close the preview", "This interface was never saved. Save it?", raven.R_MESSAGE_YES_NO_CANCEL) else raven.R_MESSAGE_RESULT_NO;
        if (answer == raven.R_MESSAGE_RESULT_CANCEL) return raven.R_FALSE;
        if (answer == raven.R_MESSAGE_RESULT_YES and save_file(raven.R_TRUE) == 0) return raven.R_FALSE;
        if (g.path == null) {
            designer_close();
            set_status("Preview closed.");
            return raven.R_TRUE;
        }
        modified = raven.R_FALSE;
    }
    const path: [*c]u8 = copy_text(g.path);
    // (the whole file: an .xmlc is whole in the XML panel)
    const text: [*c]u8 = copy_text(raven.Rtext_editor_get_text(g.source));
    designer_close();
    _ = ide.editors_open_text(path, text, modified);
    set_status("Preview closed: %s is back in a code editor.", ide.ide_basename(path));
    libc.free(text);
    libc.free(path);
    return raven.R_TRUE;
}

fn action_problems(sender: raven.Rid, action: [*c]const u8, user_data: ?*anyopaque) callconv(.c) void {
    const index: c_int = raven.Rlist_view_get_selected(g.problems_list);
    _ = sender;
    _ = action;
    _ = user_data;
    if (index < 0 or index >= g.problem_count or g.problems[@intCast(index)].line <= 0) return;
    raven.Rdock_area_show_panel(g.dock, g.source);
    raven.Rtext_editor_set_cursor(g.source, g.problems[@intCast(index)].line - 1, 0);
    raven.Rtext_editor_scroll_to_line(g.source, g.problems[@intCast(index)].line - 1);
    raven.Rwidget_focus(g.source);
}

// Actions of the interface being designed have nothing bound to them here: say what would happen.
fn on_unbound_action(sender: raven.Rid, action: [*c]const u8, user_data: ?*anyopaque) callconv(.c) void {
    _ = sender;
    _ = user_data;
    set_status("The interface fired the action \"%s\".", action);
}

// ---------------------------------------------------------------------------
//  Scripted runs
// ---------------------------------------------------------------------------

fn run_frames(count: c_int) void {
    var i: c_int = 0;
    while (i < count and raven.Ris_running() != 0) : (i += 1) {
        raven.Rwindow_request_redraw(g.window);
        _ = raven.Rdraw_frame();
    }
}

//
// Commands, separated by spaces:
//   f N            N frames            do NAME        fires an action
//   mv X Y         moves the pointer   click          left click
//   key CODE MODS  a key               text WORD      types a word
//   pick INDEX     selects a row of the palette
//   path I/J/K     selects an element by its indices from the root ("" = the root)
//   set NAME VALUE sets an attribute of the selection ('-' removes it)
//   expect TEXT    stops with an error unless the XML contains TEXT ('~' stands for a space)
//   project DIR NAME LANGUAGE   creates the project DIR/NAME (C, C++, Rust, Python, Go, C#, Zig, Lua) and opens it
//   nativeproject DIR NAME LANGUAGE   the same, native: the language alone and a Hello world
//   preview PATH   opens an interface in the visual editor (the Preview of the content drawer)
//   expectisland NAME TEXT  stops unless the label NAME of the preview of the island shows TEXT ('-': no preview there)
//   expectpanel NAME 0|1    stops unless the panel NAME of the IDE is open (1) or hidden (0)
//   wheel DY       turns the wheel (Ctrl held: key 302 2 first)
//   expectzoom Z   stops unless the XML panel, the Output and the code editor in front are zoomed Z (1.21)
//   prefix PATH    the folder of the Raven package (Build settings)
//   open PATH      opens a file as the content drawer does, or a project folder
//   expectfile PATH TEXT   stops unless the file contains TEXT
//   cell KEY COLUMN TEXT   writes a cell of the Translations panel
//   language CODE  the language of the preview ('-': the first one)
//   expectlabel NAME TEXT  stops unless the label NAME of the preview shows TEXT
//   wait SECONDS   runs frames until the build and the program are done
//   expectoutput TEXT  stops unless the Output panel contains TEXT
//   expectissue TEXT   stops unless a row of the Build panel contains TEXT
//   size W H       the size of the window          capture PATH   saves the frame now (.ppm)
//   defer S words --   the words run S seconds later, from a timer (inside a dialog that is open then)
//   clickon NAME   clicks the middle of a widget (a dialog first)   settext NAME TEXT   sets an input ('-': empty)
//   expectpage welcome|workspace   expectstatus TEXT   expecttabs TEXT (a code editor tab named like it)
//
// The next word of a script (strtok would not survive a script run from a timer inside a dialog).
fn next_token(cursor: [*c][*c]u8) [*c]u8 {
    var start: [*c]u8 = cursor.*;
    var end: [*c]u8 = undefined;
    if (start == null) return null;
    while (start.* == ' ') start += 1;
    if (start.* == 0) {
        cursor.* = null;
        return null;
    }
    end = libc.strchr(start, ' ');
    if (end != null) {
        end.* = 0;
        cursor.* = end + 1;
    } else {
        cursor.* = null;
    }
    return start;
}

fn on_deferred_script(timer: raven.Rid, user_data: ?*anyopaque) callconv(.c) void {
    const script: [*c]u8 = @ptrCast(user_data);
    _ = timer;
    if (designer_script(script) == 0) _ = fprintf(libc.stderrFile(), "raven_designer: the deferred script failed\n");
    libc.free(script);
}

// Centre of a widget found by name anywhere in the window (dialogs included).
fn find_anywhere(name: [*c]const u8) raven.Rid {
    const widget: raven.Rid = if (g_ide_dialog != raven.R_INVALID_ID and raven.Rwidget_is_valid(g_ide_dialog) != 0) raven.Rwidget_find(g_ide_dialog, name) else raven.R_INVALID_ID;
    return if (widget != raven.R_INVALID_ID) widget else raven.Rwidget_find(g.window, name);
}

fn widget_center(name: [*c]const u8, x: [*c]f32, y: [*c]f32) c_int {
    const widget: raven.Rid = find_anywhere(name);
    var wx: f32 = undefined;
    var wy: f32 = undefined;
    var ww: f32 = undefined;
    var wh: f32 = undefined;
    if (widget == raven.R_INVALID_ID) return raven.R_FALSE;
    raven.Rwidget_get_rect(widget, &wx, &wy, &ww, &wh);
    x.* = wx + ww * 0.5;
    y.* = wy + wh * 0.5;
    return raven.R_TRUE;
}

fn designer_script(script: [*c]u8) c_int {
    var cursor: [*c]u8 = script;
    var token: [*c]u8 = next_token(&cursor);
    while (token != null) {
        if (libc.strcmp(token, "f") == 0) {
            run_frames(libc.atoi(next_token(&cursor)));
        } else if (libc.strcmp(token, "do") == 0) {
            raven.Raction_fire(next_token(&cursor), raven.R_INVALID_ID);
        } else if (libc.strcmp(token, "mv") == 0) {
            const x: f32 = @floatCast(atof(next_token(&cursor)));
            const y: f32 = @floatCast(atof(next_token(&cursor)));
            raven.Rwindow_inject_mouse_move(g.window, x, y);
        } else if (libc.strcmp(token, "click") == 0) {
            raven.Rwindow_inject_mouse_button(g.window, raven.R_MOUSE_LEFT, raven.R_TRUE);
            raven.Rwindow_inject_mouse_button(g.window, raven.R_MOUSE_LEFT, raven.R_FALSE);
        } else if (libc.strcmp(token, "key") == 0) {
            const key: c_int = libc.atoi(next_token(&cursor));
            const modifiers: c_int = libc.atoi(next_token(&cursor));
            raven.Rwindow_inject_key(g.window, @bitCast(key), raven.R_TRUE, @bitCast(modifiers));
            raven.Rwindow_inject_key(g.window, @bitCast(key), raven.R_FALSE, @bitCast(modifiers));
        } else if (libc.strcmp(token, "text") == 0) {
            raven.Rwindow_inject_text(g.window, next_token(&cursor));
        } else if (libc.strcmp(token, "pick") == 0) {
            raven.Rlist_view_set_selected(g.palette, libc.atoi(next_token(&cursor)));
        } else if (libc.strcmp(token, "path") == 0) {
            var text: [*c]u8 = next_token(&cursor);
            var path: [32]c_int = undefined;
            var depth: c_int = 0;
            while (text != null and text.* != 0 and text.* != '.' and depth < 32) {
                path[@intCast(depth)] = libc.atoi(text);
                depth += 1;
                text = libc.strchr(text, '/');
                if (text != null) text += 1;
            }
            select_node(node_at_path(&path, depth), raven.R_TRUE);
        } else if (libc.strcmp(token, "set") == 0) {
            const name: [*c]const u8 = next_token(&cursor);
            const value: [*c]const u8 = next_token(&cursor);
            raven.Rxml_node_set_attribute(g.selected, name, if (libc.strcmp(value, "-") == 0) null else value);
            document_changed(raven.R_FALSE);
        } else if (libc.strcmp(token, "expect") == 0) {
            const text: [*c]u8 = next_token(&cursor);
            var cursor_: [*c]u8 = undefined;
            cursor_ = text;
            while (cursor_.* != 0) : (cursor_ += 1) {
                if (cursor_.* == '~') cursor_.* = ' ';
            }
            if (libc.strstr(raven.Rtext_editor_get_text(g.source), text) == null) {
                _ = fprintf(libc.stderrFile(), "raven_designer: expected the XML to contain: %s\n---\n%s---\n", text, raven.Rtext_editor_get_text(g.source));
                return raven.R_FALSE;
            }
        } else if (libc.strcmp(token, "project") == 0 or libc.strcmp(token, "nativeproject") == 0) {
            const with_interface: c_int = @intFromBool(libc.strcmp(token, "project") == 0);
            const folder: [*c]u8 = next_token(&cursor);
            const name: [*c]u8 = next_token(&cursor);
            const language: [*c]u8 = next_token(&cursor);
            if (ide.project_create(folder, name, if (language != null and libc.strcmp(language, "-") != 0) language else "C", with_interface) == 0) {
                _ = fprintf(libc.stderrFile(), "raven_designer: cannot create the project %s in %s\n", name, folder);
                return raven.R_FALSE;
            }
        } else if (libc.strcmp(token, "preview") == 0) {
            ide.ide_preview_file(next_token(&cursor));
        } else if (libc.strcmp(token, "expectisland") == 0) {
            const name: [*c]u8 = next_token(&cursor);
            const text: [*c]u8 = next_token(&cursor);
            var c: [*c]u8 = undefined;
            const preview: raven.Rid = ide.island_preview_widget();
            const label: raven.Rid = if (preview != raven.R_INVALID_ID and libc.strcmp(name, "-") != 0) raven.Rwidget_find(preview, name) else raven.R_INVALID_ID;
            c = text;
            while (c.* != 0) : (c += 1) {
                if (c.* == '~') c.* = ' ';
            }
            if (if (libc.strcmp(name, "-") == 0) preview != raven.R_INVALID_ID else (label == raven.R_INVALID_ID or libc.strcmp(raven.Rlabel_get_text(label), text) != 0)) {
                _ = fprintf(libc.stderrFile(), "raven_designer: expected the island to show %s \"%s\", it shows %s\n", name, text, @as([*c]const u8, if (preview == raven.R_INVALID_ID) "no preview" else if (label != raven.R_INVALID_ID) raven.Rlabel_get_text(label) else "a preview"));
                return raven.R_FALSE;
            }
        } else if (libc.strcmp(token, "expectpanel") == 0) {
            const name: [*c]u8 = next_token(&cursor);
            const open: c_int = libc.atoi(next_token(&cursor));
            if (raven.Rdock_area_is_panel_open(g.dock, find_anywhere(name)) != open) {
                _ = fprintf(libc.stderrFile(), "raven_designer: expected the panel %s to be %s\n", name, @as([*c]const u8, if (open != 0) "open" else "hidden"));
                return raven.R_FALSE;
            }
        } else if (libc.strcmp(token, "wheel") == 0) {
            raven.Rwindow_inject_mouse_wheel(g.window, 0.0, @floatCast(atof(next_token(&cursor))));
        } else if (libc.strcmp(token, "expectzoom") == 0) {
            const zoom: f32 = @floatCast(atof(next_token(&cursor)));
            var editors: [3]raven.Rid = undefined;
            var k: c_int = undefined;
            editors[0] = g.source;
            editors[1] = raven.Rwidget_find(g.window, "output");
            editors[2] = if (ide.editors_current_path() != null) ide.editors_find(ide.editors_current_path()) else g.source;
            k = 0;
            while (k < 3) : (k += 1) {
                if (@abs(raven.Rtext_editor_get_zoom(editors[@intCast(k)]) - zoom) > 0.005) {
                    _ = fprintf(libc.stderrFile(), "raven_designer: expected the editors at zoom %.2f, one is at %.2f\n", @as(f64, zoom), @as(f64, raven.Rtext_editor_get_zoom(editors[@intCast(k)])));
                    return raven.R_FALSE;
                }
            }
        } else if (libc.strcmp(token, "prefix") == 0) {
            _ = libc.snprintf(&ide.g_settings.raven_prefix, ide.g_settings.raven_prefix.len, "%s", next_token(&cursor));
        } else if (libc.strcmp(token, "open") == 0) {
            const path: [*c]u8 = next_token(&cursor);
            if (ide.ide_is_dir(path) != 0) {
                _ = ide.project_open(path);
            } else {
                ide.ide_open_file(path, 0);
            }
        } else if (libc.strcmp(token, "expectfile") == 0) {
            const path: [*c]u8 = next_token(&cursor);
            const text: [*c]u8 = next_token(&cursor);
            var cursor_: [*c]u8 = undefined;
            var size: usize = 0;
            const content: [*c]u8 = raven.Rfile_read(path, &size);
            cursor_ = text;
            while (cursor_.* != 0) : (cursor_ += 1) {
                if (cursor_.* == '~') cursor_.* = ' ';
            }
            if (content == null or libc.strstr(content, text) == null) {
                _ = fprintf(libc.stderrFile(), "raven_designer: expected %s to contain: %s\n---\n%s---\n", path, text, @as([*c]const u8, if (content != null) content else "(cannot read it)"));
                if (content != null) raven.Rmemory_free(content);
                return raven.R_FALSE;
            }
            raven.Rmemory_free(content);
        } else if (libc.strcmp(token, "cell") == 0) {
            const key: [*c]u8 = next_token(&cursor);
            const column: c_int = libc.atoi(next_token(&cursor));
            const text: [*c]u8 = next_token(&cursor);
            var cursor_: [*c]u8 = undefined;
            cursor_ = text;
            while (cursor_.* != 0) : (cursor_ += 1) {
                if (cursor_.* == '~') cursor_.* = ' ';
            }
            if (ide.strings_set_cell(key, column, text) == 0) {
                _ = fprintf(libc.stderrFile(), "raven_designer: no key %s in the table\n", key);
                return raven.R_FALSE;
            }
        } else if (libc.strcmp(token, "language") == 0) {
            const code: [*c]u8 = next_token(&cursor);
            ide.strings_set_preview_language(if (libc.strcmp(code, "-") == 0) "" else code);
        } else if (libc.strcmp(token, "wait") == 0) {
            const until: f64 = raven.Rget_time() + atof(next_token(&cursor));
            while (ide.build_is_running() != 0 and raven.Rget_time() < until and raven.Ris_running() != 0) {
                raven.Rwindow_request_redraw(g.window);
                _ = raven.Rwait_frame(0.02);
            }
        } else if (libc.strcmp(token, "expectoutput") == 0) {
            const text: [*c]u8 = next_token(&cursor);
            var cursor_: [*c]u8 = undefined;
            const output: [*c]const u8 = raven.Rtext_editor_get_text(raven.Rwidget_find(g.window, "output"));
            cursor_ = text;
            while (cursor_.* != 0) : (cursor_ += 1) {
                if (cursor_.* == '~') cursor_.* = ' ';
            }
            if (libc.strstr(output, text) == null) {
                _ = fprintf(libc.stderrFile(), "raven_designer: expected the Output to contain: %s\n---\n%s---\n", text, output);
                return raven.R_FALSE;
            }
        } else if (libc.strcmp(token, "expectissue") == 0) {
            const text: [*c]u8 = next_token(&cursor);
            var cursor_: [*c]u8 = undefined;
            const list: raven.Rid = raven.Rwidget_find(g.window, "build.problems");
            var k: c_int = undefined;
            var found: c_int = 0;
            cursor_ = text;
            while (cursor_.* != 0) : (cursor_ += 1) {
                if (cursor_.* == '~') cursor_.* = ' ';
            }
            k = 0;
            while (k < raven.Rlist_view_get_item_count(list)) : (k += 1) {
                if (libc.strstr(raven.Rlist_view_get_item_text(list, k), text) != null) found = 1;
            }
            if (found == 0) {
                _ = fprintf(libc.stderrFile(), "raven_designer: no build problem contains: %s\n", text);
                k = 0;
                while (k < raven.Rlist_view_get_item_count(list)) : (k += 1) _ = fprintf(libc.stderrFile(), "  %s\n", raven.Rlist_view_get_item_text(list, k));
                return raven.R_FALSE;
            }
        } else if (libc.strcmp(token, "expectlabel") == 0) {
            const name: [*c]u8 = next_token(&cursor);
            const text: [*c]u8 = next_token(&cursor);
            var cursor_: [*c]u8 = undefined;
            const label: raven.Rid = if (g.preview != raven.R_INVALID_ID) raven.Rwidget_find(g.preview, name) else raven.R_INVALID_ID;
            cursor_ = text;
            while (cursor_.* != 0) : (cursor_ += 1) {
                if (cursor_.* == '~') cursor_.* = ' ';
            }
            if (label == raven.R_INVALID_ID or libc.strcmp(raven.Rlabel_get_text(label), text) != 0) {
                _ = fprintf(libc.stderrFile(), "raven_designer: expected the label %s to show \"%s\", it shows \"%s\"\n", name, text, @as([*c]const u8, if (label != raven.R_INVALID_ID) raven.Rlabel_get_text(label) else "(no such label)"));
                return raven.R_FALSE;
            }
        } else if (libc.strcmp(token, "size") == 0) {
            const w: c_int = libc.atoi(next_token(&cursor));
            const h: c_int = libc.atoi(next_token(&cursor));
            raven.Rwindow_set_size(g.window, w, h);
        } else if (libc.strcmp(token, "capture") == 0) {
            run_frames(2);
            capture(next_token(&cursor));
        } else if (libc.strcmp(token, "defer") == 0) {
            // defer SECONDS words -- : the words run later, from a timer (a dialog may be open then)
            const seconds: f64 = atof(next_token(&cursor));
            var later: ide.ide_buffer_t = std.mem.zeroes(ide.ide_buffer_t);
            var word: [*c]u8 = undefined;
            while (true) {
                word = next_token(&cursor);
                if (!(word != null and libc.strcmp(word, "--") != 0)) break;
                if (later.size != 0) ide.ide_buffer_add(&later, " ", 1);
                ide.ide_buffer_add(&later, word, libc.strlen(word));
            }
            _ = raven.Rtimer_create(seconds, raven.R_FALSE, &on_deferred_script, if (later.data != null) later.data else ide.ide_strdup(""));
        } else if (libc.strcmp(token, "clickon") == 0) {
            var x: f32 = undefined;
            var y: f32 = undefined;
            const name: [*c]u8 = next_token(&cursor);
            if (widget_center(name, &x, &y) == 0) {
                _ = fprintf(libc.stderrFile(), "raven_designer: no widget named %s\n", name);
                return raven.R_FALSE;
            }
            raven.Rwindow_inject_mouse_move(g.window, x, y);
            run_frames(1);
            raven.Rwindow_inject_mouse_button(g.window, raven.R_MOUSE_LEFT, raven.R_TRUE);
            raven.Rwindow_inject_mouse_button(g.window, raven.R_MOUSE_LEFT, raven.R_FALSE);
            run_frames(1);
        } else if (libc.strcmp(token, "settext") == 0) {
            const name: [*c]u8 = next_token(&cursor);
            const text: [*c]u8 = next_token(&cursor);
            var c: [*c]u8 = undefined;
            c = text;
            while (c.* != 0) : (c += 1) {
                if (c.* == '~') c.* = ' ';
            }
            raven.Rtext_input_set_text(find_anywhere(name), if (libc.strcmp(text, "-") != 0) text else "");
        } else if (libc.strcmp(token, "expectpage") == 0) {
            const page: [*c]u8 = next_token(&cursor);
            if (@intFromBool(libc.strcmp(page, "welcome") == 0) != ide.welcome_is_shown()) {
                _ = fprintf(libc.stderrFile(), "raven_designer: expected the page %s\n", page);
                return raven.R_FALSE;
            }
        } else if (libc.strcmp(token, "expectstatus") == 0) {
            const text: [*c]u8 = next_token(&cursor);
            var c: [*c]u8 = undefined;
            c = text;
            while (c.* != 0) : (c += 1) {
                if (c.* == '~') c.* = ' ';
            }
            if (libc.strstr(raven.Rlabel_get_text(g.status), text) == null) {
                _ = fprintf(libc.stderrFile(), "raven_designer: expected the status to contain \"%s\", it is \"%s\"\n", text, raven.Rlabel_get_text(g.status));
                return raven.R_FALSE;
            }
        } else if (libc.strcmp(token, "expecttabs") == 0) {
            // expecttabs TEXT: a code editor tab whose title contains TEXT is open
            const text: [*c]u8 = next_token(&cursor);
            var c: [*c]u8 = undefined;
            c = text;
            while (c.* != 0) : (c += 1) {
                if (c.* == '~') c.* = ' ';
            }
            if (ide.editors_find_title(text) == raven.R_INVALID_ID) {
                _ = fprintf(libc.stderrFile(), "raven_designer: no code editor named like %s\n", text);
                return raven.R_FALSE;
            }
        } else {
            _ = fprintf(libc.stderrFile(), "raven_designer: unknown script command '%s'\n", token);
            return raven.R_FALSE;
        }
        token = next_token(&cursor);
    }
    return raven.R_TRUE;
}

fn capture(path: [*c]const u8) void {
    var width: c_int = 0;
    var height: c_int = 0;
    var i: c_int = undefined;
    const pixels: [*c]u8 = raven.Rwindow_capture(g.window, &width, &height);
    const file: ?*libc.FILE = if (pixels != null) libc.fopen(path, "wb") else null;
    if (file) |f| {
        _ = fprintf(f, "P6\n%d %d\n255\n", width, height);
        i = 0;
        while (i < width * height) : (i += 1) _ = libc.fwrite(pixels + @as(usize, @intCast(i * 4)), 1, 3, f);
        _ = libc.fclose(f);
    }
    raven.Rpixels_free(pixels);
}

// ---------------------------------------------------------------------------
//  Start
// ---------------------------------------------------------------------------

fn build_interface() c_int {
    const edits = [_][*c]const u8{
        "edit.delete",    "edit.duplicate", "edit.up",          "edit.down",           "edit.out",          "edit.in", "edit.unwrap", "edit.copy", "edit.paste",
        "edit.wrap.VBox", "edit.wrap.HBox", "edit.wrap.Border", "edit.wrap.ScrollBox", "edit.wrap.Overlay",
    };
    const files = [_][*c]const u8{ "file.new.window", "file.new.panel", "file.new.form", "file.open", "file.welcome", "file.save", "file.save_as", "file.save_all", "file.quit" };
    const views = [_][*c]const u8{
        "view.theme.dark", "view.theme.light", "view.theme.glass_dark", "view.theme.glass_light", "view.interact",   "view.interact.switch",
        "view.run",        "view.reset",       "view.preview",          "view.preview.close",     "view.zoom.reset",
    };
    const context = [_]struct { text: [*c]const u8, action: [*c]const u8 }{
        .{ .text = "Duplicate", .action = "edit.duplicate" },          .{ .text = "Delete", .action = "edit.delete" },            .{ .text = null, .action = null },
        .{ .text = "Move up", .action = "edit.up" },                   .{ .text = "Move down", .action = "edit.down" },           .{ .text = "Move out", .action = "edit.out" },
        .{ .text = null, .action = null },                             .{ .text = "Wrap in a VBox", .action = "edit.wrap.VBox" }, .{ .text = "Wrap in an HBox", .action = "edit.wrap.HBox" },
        .{ .text = "Wrap in a Border", .action = "edit.wrap.Border" }, .{ .text = "Unwrap", .action = "edit.unwrap" },            .{ .text = null, .action = null },
        .{ .text = "Copy as XML", .action = "edit.copy" },             .{ .text = "Paste XML inside", .action = "edit.paste" },
    };
    var i: usize = undefined;

    i = 0;
    while (i < edits.len) : (i += 1) raven.Raction_bind(edits[i], &action_edit, null);
    i = 0;
    while (i < files.len) : (i += 1) raven.Raction_bind(files[i], &action_file, null);
    i = 0;
    while (i < views.len) : (i += 1) raven.Raction_bind(views[i], &action_view, null);
    raven.Raction_bind("edit.undo", &action_history, null);
    raven.Raction_bind("edit.redo", &action_history, null);
    raven.Raction_bind("palette.add", &action_palette_add, null);
    raven.Raction_bind("palette.filter", &action_palette_filter, null);
    raven.Raction_bind("problems.go", &action_problems, null);
    raven.Raction_set_default_handler(&on_unbound_action, null);

    {
        var length: usize = 0;
        var piece: usize = undefined;
        piece = 0;
        while (piece < DESIGNER_XML.len) : (piece += 1) length += libc.strlen(DESIGNER_XML[piece]);
        const xml: [*c]u8 = @ptrCast(libc.malloc(length + 1));
        xml[0] = 0;
        piece = 0;
        while (piece < DESIGNER_XML.len) : (piece += 1) _ = strcat(xml, DESIGNER_XML[piece]);
        g.window = raven.Rwindow_create_from_xml(xml, length);
        libc.free(xml);
    }
    if (g.window == raven.R_INVALID_ID) return raven.R_FALSE;
    g.dock = raven.Rwidget_find(g.window, "dock");
    g.source = raven.Rwidget_find(g.window, "source");
    g.tree = raven.Rwidget_find(g.window, "tree");
    g.palette = raven.Rwidget_find(g.window, "palette");
    g.palette_filter = raven.Rwidget_find(g.window, "palette.filter");
    g.inspector = raven.Rwidget_find(g.window, "inspector");
    g.problems_list = raven.Rwidget_find(g.window, "problems");
    g.status = raven.Rwidget_find(g.window, "status");
    g.path_label = raven.Rwidget_find(g.window, "path");
    g.stage = raven.Rwidget_find(g.window, "stage");
    g.interact_switch = raven.Rwidget_find(g.window, "interact");
    g_ide_window = g.window;
    g_ide_dock = g.dock;
    g_ide_center = raven.Rwidget_find(g.window, "panel.preview");
    raven.Rdock_area_show_panel(g.dock, g.source);
    // the arrangement the panels start with, for "Reset the panels"
    raven.Rwidget_set_user_handle(g.dock, copy_text(raven.Rdock_area_save_layout(g.dock)));

    // the stage: a frame that stands for the window, and above it what draws the selection
    g.frame = raven.Rwidget_create(raven.R_WIDGET_BORDER);
    _ = raven.Rwidget_set_attribute(g.frame, "CornerRadius", "10");
    _ = raven.Rwidget_set_attribute(g.frame, "BorderWidth", "1");
    _ = raven.Rwidget_set_attribute(g.frame, "Shadow", "26,0,10");
    raven.Rwidget_set_clipping(g.frame, raven.R_TRUE);
    _ = raven.Rwidget_add_child(g.stage, g.frame);
    g.outline = raven.Rwidget_create(raven.R_WIDGET_CUSTOM);
    raven.Rcustom_set_paint_callback(g.outline, &outline_paint, null);
    raven.Rwidget_set_event_callback(g.outline, &outline_event, null);
    raven.Rwidget_set_focusable(g.outline, raven.R_TRUE);
    _ = raven.Rwidget_add_child(g.stage, g.outline);

    g.context_menu = raven.Rwidget_create(raven.R_WIDGET_MENU);
    i = 0;
    while (i < context.len) : (i += 1) {
        if (context[i].text == null) {
            _ = raven.Rmenu_add_separator(g.context_menu);
        } else {
            raven.Rwidget_set_action(raven.Rmenu_add_item(g.context_menu, context[i].text), context[i].action);
        }
    }
    raven.Rwidget_set_context_menu(g.tree, g.context_menu);

    raven.Rtree_view_set_selection_changed_callback(g.tree, &on_tree_selected, null);
    raven.Rtext_editor_set_changed_callback(g.source, &on_source_changed, null);
    raven.Rtext_editor_set_tab_size(g.source, 4);
    raven.Rwindow_set_close_callback(g.window, &on_close, null);
    raven.Rwindow_set_drop_callback(g.window, &on_drop, null);

    g.row_cap = 512;
    g.rows = @ptrCast(@alignCast(libc.calloc(@intCast(g.row_cap), @sizeOf(row_t))));
    g.document = raven.R_INVALID_ID;
    g.selected = raven.R_INVALID_ID;
    g.hovered = raven.R_INVALID_ID;
    g.preview = raven.R_INVALID_ID;
    g.run_window = raven.R_INVALID_ID;
    g.parse_timer = raven.R_INVALID_ID;

    // the IDE around the visual editor
    ide.completion_attach(g.source, raven.R_TRUE);
    ide.editors_init();
    ide.build_init();
    ide.strings_init();
    ide.project_init();
    ide.welcome_init();
    ide.accessibility_init();
    ide.drawer_init(raven.Rwidget_find(g.window, "main.overlay"));
    ide.island_init();
    // (after welcome_init: the zoom of the text is one of the preferences)
    ide.editors_zoom_attach(g.source);
    ide.editors_zoom_attach(raven.Rwidget_find(g.window, "output"));
    raven.Rdock_area_show_panel(g.dock, g.source);
    return raven.R_TRUE;
}

export fn main(argc: c_int, argv: [*c][*c]u8) c_int {
    var desc: raven.RInitDesc = undefined;
    var file: [*c]const u8 = null;
    var capture_path: [*c]const u8 = null;
    var script: [*c]u8 = null;
    var frames: c_int = -1;
    var i: c_int = undefined;
    var ok: c_int = raven.R_TRUE;

    desc = std.mem.zeroes(raven.RInitDesc);
    desc.backend = raven.R_BACKEND_VULKAN;
    desc.app_name = "Raven IDE";
    i = 1;
    while (i < argc) : (i += 1) {
        if (libc.strcmp(argv[@intCast(i)], "--null") == 0) {
            desc.backend = raven.R_BACKEND_NULL;
            desc.headless = raven.R_TRUE;
        } else if (libc.strcmp(argv[@intCast(i)], "--headless") == 0) {
            desc.headless = raven.R_TRUE;
        } else if (libc.strcmp(argv[@intCast(i)], "--frames") == 0 and i + 1 < argc) {
            i += 1;
            frames = libc.atoi(argv[@intCast(i)]);
        } else if (libc.strcmp(argv[@intCast(i)], "--script") == 0 and i + 1 < argc) {
            i += 1;
            script = copy_text(argv[@intCast(i)]);
        } else if (libc.strcmp(argv[@intCast(i)], "--capture") == 0 and i + 1 < argc) {
            i += 1;
            capture_path = argv[@intCast(i)];
        } else if (argv[@intCast(i)][0] == '-') {
            _ = fprintf(libc.stderrFile(), "usage: raven_designer [project folder | file.xml | file.xmlc] [--null | --headless] [--frames N] [--script \"...\"] [--capture file.ppm]\n");
            return 2;
        } else {
            file = argv[@intCast(i)];
        }
    }
    raven.Rerror_set_callback(&on_error);
    if (raven.Rinit_ex(&desc) == 0) {
        _ = fprintf(libc.stderrFile(), "raven_designer: cannot start Raven (is a Vulkan driver installed?)\n");
        return 1;
    }
    // scripted runs do not depend on how long a frame takes
    if (frames >= 0 or script != null) {
        raven.Rset_animation_time_step(1.0 / 60.0);
        g.quitting = raven.R_TRUE;
    }
    // the IDE reads from left to right whatever the language of the preview (the preview has its own direction)
    raven.Rset_layout_direction(raven.R_DIRECTION_LTR);
    if (build_interface() == 0) {
        raven.Rshutdown();
        return 1;
    }
    // the theme of the last time (not for the scripted runs: they start the same way everywhere)
    if (g.quitting == 0 and ide.prefs_get("theme")[0] != 0) {
        var action: [64]u8 = undefined;
        _ = libc.snprintf(&action, action.len, "view.theme.%s", ide.prefs_get("theme"));
        raven.Raction_fire(&action, raven.R_INVALID_ID);
    }
    // the accessibility settings of the last time (text size, contrast, motion...)
    if (g.quitting == 0) ide.accessibility_apply_saved();
    // nothing is opened by itself: the start page, unless a project or a file was given
    designer_close();
    if (file != null and ide.ide_is_dir(file) != 0) {
        _ = ide.project_open(file);
    } else if (file != null) {
        ide.ide_open_file(file, 0);
    } else {
        ide.welcome_show();
    }
    update_title();

    if (script != null) ok = designer_script(script);
    if (frames >= 0) {
        run_frames(frames);
        if (capture_path != null) capture(capture_path);
    } else if (script == null) {
        while (raven.Rwait_frame(-1.0) != 0) {}
    }

    ide.build_shutdown();
    ide.island_shutdown();
    ide.drawer_shutdown();
    ide.accessibility_shutdown();
    ide.welcome_shutdown();
    if (ide.xmlc_is_open() != 0) ide.xmlc_close();
    ide.strings_shutdown();
    ide.editors_shutdown();
    ide.project_shutdown();
    history_clear();
    i = 0;
    while (i < g.palette_count) : (i += 1) libc.free(g.palette_tags[@intCast(i)]);
    libc.free(@ptrCast(g.palette_tags));
    libc.free(g.rows);
    libc.free(g.path);
    libc.free(script);
    if (raven.Rwidget_is_valid(g.dock) != 0) libc.free(raven.Rwidget_get_user_handle(g.dock));
    i = raven.Rget_exit_code();
    raven.Rshutdown();
    return if (ok != 0) i else 1;
}
