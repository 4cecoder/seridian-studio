// Translated to Zig from vendor/raven/src/xml/xml_schema.c (Raven, Apache-2.0). Modified by Seridian: C11 → Zig translation.
//
// Raven - xml/xml_schema.c
// What can be written in XML, as data: the tags and, for each, its
// attributes with the kind of value they take (Rxml_get_tag_...,
// Rxml_get_attribute_...). Tools use it to propose and to check; the loader
// does not: an attribute exists because a class accepts it. The two are kept
// together by tests/test_xml.c, which gives every attribute listed here to
// the loader.

const raven = @import("raven");
const base = @import("../core/base_h.zig");
const xml = @import("xml_h.zig");
const widget_h = @import("../widget/widget_h.zig");
const libc = @import("../sys/libc.zig");

const rvn_schema_attribute_t = struct {
    name: [*c]const u8,
    type: raven.RXmlValueType,
    choices: [*c]const u8,
    description: [*c]const u8,
};

inline fn T(name: [*c]const u8, description: [*c]const u8) rvn_schema_attribute_t {
    return .{ .name = name, .type = raven.R_XML_TEXT, .choices = null, .description = description };
}
inline fn B(name: [*c]const u8, description: [*c]const u8) rvn_schema_attribute_t {
    return .{ .name = name, .type = raven.R_XML_BOOL, .choices = null, .description = description };
}
inline fn N(name: [*c]const u8, description: [*c]const u8) rvn_schema_attribute_t {
    return .{ .name = name, .type = raven.R_XML_NUMBER, .choices = null, .description = description };
}
inline fn C(name: [*c]const u8, choices: [*c]const u8, description: [*c]const u8) rvn_schema_attribute_t {
    return .{ .name = name, .type = raven.R_XML_CHOICE, .choices = choices, .description = description };
}
inline fn K(name: [*c]const u8, description: [*c]const u8) rvn_schema_attribute_t {
    return .{ .name = name, .type = raven.R_XML_COLOR, .choices = null, .description = description };
}
inline fn A(name: [*c]const u8, description: [*c]const u8) rvn_schema_attribute_t {
    return .{ .name = name, .type = raven.R_XML_ACTION, .choices = null, .description = description };
}
inline fn F(name: [*c]const u8, description: [*c]const u8) rvn_schema_attribute_t {
    return .{ .name = name, .type = raven.R_XML_FILE, .choices = null, .description = description };
}
inline fn V(name: [*c]const u8, description: [*c]const u8) rvn_schema_attribute_t {
    return .{ .name = name, .type = raven.R_XML_NUMBERS, .choices = null, .description = description };
}
inline fn L(name: [*c]const u8, description: [*c]const u8) rvn_schema_attribute_t {
    return .{ .name = name, .type = raven.R_XML_LIST, .choices = null, .description = description };
}

const ORIENTATION = "Horizontal|Vertical";
const STRETCH = "Fill|Fit|Cover|None";

// ---- what every widget has ----

const g_widget = [_]rvn_schema_attribute_t{
    T("Name", "Name of the widget, for Rwidget_find."),
    N("Width", "Fixed width; a negative value lets the content decide."),
    N("Height", "Fixed height; a negative value lets the content decide."),
    N("MinWidth", "The width never goes below this."),
    N("MinHeight", "The height never goes below this."),
    N("MaxWidth", "The width never goes above this."),
    N("MaxHeight", "The height never goes above this."),
    C("Visibility", "Visible|Hidden|Collapsed", "Hidden keeps the place of the widget, Collapsed gives it back."),
    B("Enabled", "A disabled widget is dimmed and does not react."),
    N("Opacity", "From 0 (invisible) to 1."),
    C("Material", "Default|Solid|Glass|FrostedGlass|TintedGlass", "What the surface of the widget is made of; Default follows the theme."),
    T("Tooltip", "Text shown when the pointer rests on the widget."),
    C("Cursor", "Arrow|IBeam|Hand|Crosshair|ResizeH|ResizeV|ResizeNWSE|ResizeNESW|Move|NotAllowed|None", "Pointer shown over the widget."),
    C("Appear", "None|Fade|Pop|Zoom|FlyUp|FlyDown|FlyLeft|FlyRight|Drop|SlideLeft|SlideRight", "How the widget comes in when it is first shown."),
    N("AppearDelay", "Seconds before the widget comes in."),
    A("Action", "Name of the action the widget fires."),
    B("HitTestable", "false lets the pointer through to what is behind."),
    B("Focusable", "Can take the keyboard."),
    B("Clip", "Cuts what is inside at the bounds of the widget."),
    B("WindowDrag", "Dragging the widget moves the window (custom header)."),
    T("Class", "Style classes of the widget, separated by spaces: the styles of the theme that name one of them apply."),
    C("Theme", "Default|Dark|Light|GlassDark|GlassLight|HighContrastDark|HighContrastLight", "Theme of the widget and of what it contains: a name, or a theme file; Default follows what is around."),
    C("Direction", "Inherit|LTR|RTL", "Right to left: the children placed as in a mirror, the texts aligned on the right (raven_layout.h)."),
    T("AccessibleName", "What a screen reader says of the widget (its text by default)."),
    T("AccessibleDescription", "A longer explanation, read after the name."),
    C("AccessibleRole", "Auto|None|Group|Text|Heading|Link|Button|ToggleButton|CheckBox|RadioButton|Slider|ProgressBar|SpinButton|TextField|Document|ComboBox|List|ListItem|Tree|TreeItem|Table|MenuBar|Menu|MenuItem|TabList|Tab|TabPanel|Toolbar|StatusBar|Dialog|Alert|Image|Canvas|Separator|ScrollBar|Pane", "What the widget is for a screen reader."),
    B("AccessibleHidden", "Hidden from screen readers, with what it contains (decoration)."),
};

// ---- the place of a widget in its parent ----

const g_slot = [_]rvn_schema_attribute_t{
    N("Slot.Fill", "Share of the free space of the panel the widget takes; 0 keeps its own size."),
    V("Slot.Padding", "Space around the widget: one number, \"x,y\" or \"left,top,right,bottom\"."),
    C("Slot.HAlign", "Fill|Left|Center|Right", "Where the widget sits across its place."),
    C("Slot.VAlign", "Fill|Top|Center|Bottom", "Where the widget sits down its place."),
    B("Slot.Auto", "Takes its own size (the opposite of Slot.Fill)."),
    N("Slot.MaxSize", "The most a filling widget takes along the panel."),
    N("Slot.Column", "Grid: column, from 0."),
    N("Slot.Row", "Grid: row, from 0."),
    N("Slot.ColumnSpan", "Grid: number of columns taken."),
    N("Slot.RowSpan", "Grid: number of rows taken."),
    V("Slot.Anchors", "Canvas: \"x,y\" or \"minx,miny,maxx,maxy\", from 0 to 1 across the canvas."),
    V("Slot.Position", "Canvas: \"x,y\" from the anchor."),
    V("Slot.Size", "Canvas: \"width,height\"."),
    V("Slot.Alignment", "Canvas: \"x,y\", the point of the widget placed at the position, from 0 to 1."),
    T("Slot.Title", "Title of the tab or of the docked panel that holds the widget."),
    C("Slot.Dock", "Left|Right|Top|Bottom|Tab", "DockArea: the side of the area, or of Slot.DockTo, the panel takes."),
    T("Slot.DockTo", "DockArea: name of the panel the panel is placed against."),
    N("Slot.DockSize", "DockArea: share of the place it is cut from, between 0 and 1."),
    B("Slot.Closable", "DockArea: the tab has a close button."),
};

// ---- colors and metrics of the theme, for one widget and what it contains ----

const g_colors = [_]rvn_schema_attribute_t{
    K("Color.Window", ""),          K("Color.Panel", ""),          K("Color.Border", ""),         K("Color.Text", ""),          K("Color.TextDisabled", ""),
    K("Color.TextPlaceholder", ""), K("Color.Accent", ""),         K("Color.AccentHovered", ""),  K("Color.AccentPressed", ""), K("Color.AccentText", ""),
    K("Color.Control", ""),         K("Color.ControlHovered", ""), K("Color.ControlPressed", ""), K("Color.ControlBorder", ""), K("Color.Input", ""),
    K("Color.Focus", ""),           K("Color.Selection", ""),      K("Color.RowHovered", ""),     K("Color.Track", ""),         K("Color.Handle", ""),
    K("Color.HandleHovered", ""),   K("Color.Separator", ""),      K("Color.Header", ""),         K("Color.HeaderHovered", ""), K("Color.TabActive", ""),
    K("Color.Popup", ""),           K("Color.PopupBorder", ""),    K("Color.Shadow", ""),         K("Color.Tooltip", ""),       K("Color.TooltipText", ""),
    K("Color.Switch", ""),          K("Color.Success", ""),        K("Color.Warning", ""),        K("Color.Danger", ""),        K("Color.Link", ""),
    K("Color.Code", ""),
};

const g_metrics = [_]rvn_schema_attribute_t{
    N("Metric.FontSize", ""),         N("Metric.CornerRadius", ""), N("Metric.BorderWidth", ""),  N("Metric.ControlHeight", ""),
    N("Metric.PaddingX", ""),         N("Metric.PaddingY", ""),     N("Metric.Spacing", ""),      N("Metric.ScrollbarSize", ""),
    N("Metric.RowHeight", ""),        N("Metric.Indent", ""),       N("Metric.SplitterSize", ""), N("Metric.CheckSize", ""),
    N("Metric.SliderHandleSize", ""), N("Metric.PopupRadius", ""),  N("Metric.GlassFrost", ""),   N("Metric.GlassRefraction", ""),
    N("Metric.GlassSaturation", ""),  N("Metric.GlassRim", ""),     N("Metric.GlassShadow", ""),  N("Metric.BlurRadius", ""),
};

// ---- tags ----

const g_window = [_]rvn_schema_attribute_t{
    T("Title", "Title of the window."),
    N("Width", "Width of the content, in logical units."),
    N("Height", "Height of the content."),
    N("MinWidth", "The user cannot make the window narrower."),
    N("MinHeight", "The user cannot make the window shorter."),
    B("Resizable", "false fixes the size."),
    B("CustomHeader", "No title bar from the system: a HeaderBar of the interface replaces it."),
    B("Borderless", "No frame at all."),
    B("Maximized", "Starts maximized."),
    B("Hidden", "Starts hidden, until Rwindow_show."),
    K("ClearColor", "Color behind the content."),
    F("Background", "Image behind the content (what glass refracts)."),
    B("Transparent", "The window can be seen through where nothing is drawn (needs a compositing window system)."),
    C("Backdrop", "None|Transparent|Blur|Acrylic|Mica", "What the system shows behind a window that is seen through: the desktop as it is, blurred, or a material of Windows 11."),
    C("Theme", "Dark|Light|GlassDark|GlassLight|HighContrastDark|HighContrastLight", "Theme of the window: a name, or a theme file."),
};

const g_box = [_]rvn_schema_attribute_t{N("Spacing", "Space between the children.")};
const g_grid = [_]rvn_schema_attribute_t{
    T("Columns", "Share of the width of each column: \"0,1,2\" (0 = the size of its content)."),
    T("Rows", "Share of the height of each row."),
    N("Spacing", "Space between the cells."),
};
const g_uniform_grid = [_]rvn_schema_attribute_t{
    N("Columns", "Number of columns; 0 fits as many as the width allows."),
    V("MinCellSize", "\"width,height\" every cell has at least."),
    N("Spacing", "Space between the cells."),
};
const g_border = [_]rvn_schema_attribute_t{
    V("Padding", "Space between the border and its content."),
    K("Background", "Color of the surface."),
    K("BorderColor", "Color of the outline."),
    N("BorderWidth", "Width of the outline."),
    V("CornerRadius", "One number, or \"top-left,top-right,bottom-right,bottom-left\"."),
    V("Shadow", "\"blur\" or \"blur,x,y\"."),
    T("Effect", "An effect as its background: aurora, shimmer, neon, ripple, plasma, grain, spotlight, mesh, or a .spv file (raven_shader.h)."),
    K("EffectColor", "First color of the effect."),
    K("EffectColor2", "Second color of the effect."),
    V("EffectParams", "The four parameters of the effect: \"a,b,c,d\" (fewer keep the defaults of the others)."),
    B("EffectAnimate", "Draws frames while it is shown (the animated effects do by default)."),
    B("EffectPointer", "The effect follows the pointer: where it is, over the border and pressing it (true by default)."),
    B("EffectBackdrop", "The .spv effect reads what is behind it (R_SHADER_BACKDROP)."),
};
const g_size_box = [_]rvn_schema_attribute_t{V("AspectRatio", "Width over height: \"1.5\" or \"16,9\".")};
const g_scroll_box = [_]rvn_schema_attribute_t{
    C("Orientation", ORIENTATION, "The way the content scrolls and is stacked."),
    B("ScrollBoth", "Scrolls both ways."),
    N("Spacing", "Space between the children."),
};
const g_splitter = [_]rvn_schema_attribute_t{
    C("Orientation", ORIENTATION, "Horizontal puts the panes side by side."),
    N("MinPaneSize", "The smallest a pane can be dragged to."),
};
const g_switcher = [_]rvn_schema_attribute_t{N("Index", "Which child is shown, from 0.")};
const g_tab_view = [_]rvn_schema_attribute_t{ N("ActiveTab", "Which tab is shown, from 0."), A("OnChanged", "Action fired when the tab changes.") };
const g_expander = [_]rvn_schema_attribute_t{
    T("Title", "Text of the header."),
    B("Expanded", "The content is shown."),
    A("OnChanged", "Action fired when it opens or closes."),
};
const g_label = [_]rvn_schema_attribute_t{
    T("Text", "The text."),
    N("TextSize", "Size of the text; 0 uses the theme."),
    C("TextAlign", "Left|Center|Right", "Where the lines sit across the label."),
    B("Wrap", "Long lines continue on the next one."),
    K("Color", "Color of the text."),
    F("Font", "Font file, or \"monospace\"."),
    B("Markdown", "The text is Markdown: headings, emphasis, lists, quotes, code, tables, links."),
};
const g_button = [_]rvn_schema_attribute_t{
    T("Text", "The text of the button."),
    C("Style", "Default|Primary|Flat", "Primary is the button of the main action; Flat has no surface until hovered."),
    A("OnClicked", "Action fired by a click."),
};
const g_checkbox = [_]rvn_schema_attribute_t{
    T("Text", "The text beside the box."),
    B("Checked", "Its state."),
    C("Style", "Check|Radio|Switch", "What it looks like."),
    A("OnChanged", "Action fired when the state changes."),
};
const g_slider = [_]rvn_schema_attribute_t{
    N("Min", "Lowest value."),
    N("Max", "Highest value."),
    N("Value", "The value."),
    N("Step", "The value moves by this much; 0 moves freely."),
    C("Orientation", ORIENTATION, "The way the slider lies."),
    A("OnChanged", "Action fired when the value changes."),
};
const g_progress_bar = [_]rvn_schema_attribute_t{
    N("Value", "How far, from 0 to 1."),
};
const g_separator = [_]rvn_schema_attribute_t{C("Orientation", ORIENTATION, "Horizontal is a line across.")};
const g_image = [_]rvn_schema_attribute_t{
    F("Source", "Image file."),
    C("Stretch", STRETCH, "How the image fills its place."),
    K("Tint", "Color the image is multiplied by."),
    N("CornerRadius", "Rounds the corners."),
    V("Region", "Part of the image shown: \"minu,minv,maxu,maxv\" from 0 to 1."),
    B("TintText", "Tinted with the color of the text around it: white icons that follow the theme."),
};
const g_text_input = [_]rvn_schema_attribute_t{
    T("Text", "The text."),
    T("Placeholder", "Shown, dimmed, while the input is empty."),
    B("Password", "Shows dots."),
    B("ReadOnly", "Can be selected and copied, not changed."),
    N("MaxLength", "Most characters accepted; 0 for no limit."),
    A("OnChanged", "Action fired at each change."),
    A("OnCommitted", "Action fired by Enter."),
};
const g_spin_box = [_]rvn_schema_attribute_t{
    N("Min", "Lowest value."),
    N("Max", "Highest value."),
    N("Value", "The value."),
    N("Step", "What the arrows add."),
    N("Decimals", "Digits shown after the point."),
    A("OnChanged", "Action fired when the value changes."),
};
const g_combo_box = [_]rvn_schema_attribute_t{
    L("Items", "The choices, separated by '|'."),
    N("Selected", "Which one is chosen, from 0; -1 for none."),
    A("OnChanged", "Action fired when the choice changes."),
};
const g_list_view = [_]rvn_schema_attribute_t{
    L("Items", "The rows, separated by '|'."),
    N("Selected", "Which row is selected, from 0; -1 for none."),
    A("OnChanged", "Action fired when the selection changes."),
    A("OnActivated", "Action fired by a double click or Enter."),
};
const g_tree_view = [_]rvn_schema_attribute_t{
    A("OnChanged", "Action fired when the selection changes."),
    A("OnActivated", "Action fired by a double click or Enter."),
};
const g_tile_view = [_]rvn_schema_attribute_t{
    N("TileWidth", "Width of a tile."),
    C("Layout", "Tiles|Rows", "Tiles: a grid. Rows: one item per line, as wide as the view, the icon on the left."),
    N("TileHeight", "Height of a tile, name included."),
    N("IconSize", "Size of the icon of a tile."),
    N("Spacing", "Space between the tiles."),
    T("EmptyText", "Text shown when there is no tile."),
    T("DragType", "Type given to Rdrag_begin when tiles are dragged; empty: no drag."),
    A("OnActivated", "Action fired by a double click or Enter."),
};
const g_menu = [_]rvn_schema_attribute_t{T("Title", "Text of the menu in its bar, or in the menu that holds it.")};
const g_menu_item = [_]rvn_schema_attribute_t{
    T("Text", "Text of the item."),
    T("Shortcut", "Keys shown beside it and that fire it: \"Ctrl+S\"."),
    B("Checkable", "Clicking it checks and unchecks it."),
    B("Checked", "Its state."),
    B("Separator", "A line instead of an item."),
    A("OnClicked", "Action fired by the item."),
};
const g_viewport = [_]rvn_schema_attribute_t{
    C("Stretch", STRETCH, "How the picture fills its place."),
    B("FlipY", "Turns the picture upside down (some renderers draw that way)."),
    B("Realtime", "Drawn again at every frame."),
    F("Source", "Image shown until the application draws."),
};
const g_text_editor = [_]rvn_schema_attribute_t{
    T("Text", "The text."),
    C("Language", "None|C|C++|C#|Java|JavaScript|TypeScript|Python|Rust|GLSL|JSON|CSS|XML|HTML", "Colors the text and helps while typing."),
    B("LineNumbers", "Shows the line numbers in a margin."),
    B("Wrap", "Long lines continue on the next row."),
    B("ReadOnly", "Can be scrolled, selected and copied, not changed."),
    T("Placeholder", "Shown, dimmed, while the editor is empty."),
    N("TabSize", "Width of a tab, in spaces."),
    B("TabSpaces", "The Tab key writes spaces."),
    B("Completion", "Proposes words while typing."),
    B("AutoPairs", "Closes brackets and quotes, indents after them."),
    N("TextSize", "Size of the text; 0 uses the theme."),
    N("Zoom", "Zoom of the text, 1 = 100 % (0.5 .. 4): Ctrl + wheel changes it."),
    B("Zoomable", "Ctrl + wheel, Ctrl + '+' / '-' / 0 zoom the text (on by default)."),
    F("Font", "Font file, or \"monospace\"."),
    B("Markdown", "The text is Markdown, styled where it is typed (the same as Language=\"Markdown\")."),
    A("OnChanged", "Action fired at each change."),
};
const g_header_bar = [_]rvn_schema_attribute_t{
    T("Title", "Text of the bar."),
    C("Buttons", "All|None|Close|Close,Minimize|Close,Maximize", "The window buttons the bar shows."),
    C("ButtonSide", "Right|Left", "Where the window buttons are."),
    C("TitleAlign", "Center|Left", "Where the title is."),
    B("Background", "false leaves the bar without a surface, over what is behind."),
};
const g_file_browser = [_]rvn_schema_attribute_t{
    T("Directory", "Folder shown first."),
    C("Mode", "Open|Save|Folder", "What is being chosen."),
    T("Filter", "Patterns of the files shown: \"*.png;*.jpg\"."),
    T("FileName", "Save: the name proposed."),
    T("DefaultExtension", "Save: added to a name typed without one."),
    B("ShowHidden", "Shows the hidden files."),
    B("Multiple", "Open: several files can be chosen."),
    B("Controls", "false hides the name, the filter and the buttons."),
    B("Places", "false hides the list of places."),
};
const g_dock_area = [_]rvn_schema_attribute_t{
    B("Movable", "false keeps the panels where they are."),
    T("Layout", "An arrangement saved with Rdock_area_save_layout."),
    B("CloseHides", "The close button of a tab hides its panel (Rdock_area_open_panel brings it back) instead of deleting it."),
    B("Tearable", "false: a tab dragged out of the area does not take its panel to a window of its own."),
};
const g_island = [_]rvn_schema_attribute_t{
    B("Expanded", "Unfolded."),
    B("ExpandOnHover", "Unfolds while the pointer is over it."),
    B("ExpandOnClick", "A click unfolds it and folds it back."),
    B("Attached", "Hangs from the top edge, like a notch, instead of floating below it."),
};
const g_background_blur = [_]rvn_schema_attribute_t{
    C("Style", "Plain|Frosted|Glass|Native", "Plain only blurs; Frosted adds a veil and grain; Glass bends light at its rim; Native shows the desktop, blurred by the system, through a window that is seen through."),
    N("Radius", "How far the blur spreads; 0 uses the theme."),
    K("Tint", "Color laid over what is blurred; its alpha is its strength."),
    N("Saturation", "Colors of what is behind: 1 unchanged, 0 gray, more than 1 vivid."),
    N("Grain", "Fine noise, from 0 to 1 (what keeps a blur from banding)."),
    N("Shadow", "Blur of the shadow under the panel; 0 = none."),
    V("Padding", "Space around the child."),
    N("CornerRadius", "Radius of the corners."),
};
const g_color_picker = [_]rvn_schema_attribute_t{
    K("Color", "The color."),
    K("Previous", "The color shown next to it, to compare."),
    B("Alpha", "Shows the opacity strip; false makes colors opaque."),
    B("Popup", "A swatch the size of a button, that opens the picker when clicked."),
    B("Compact", "Only the square, the hues and the opacity."),
    C("Numbers", "RGB|HSV", "The numbers shown under the square."),
    T("Swatches", "Colors proposed under the picker: \"#FF453A, #0A84FF, white\"."),
    A("OnChanged", "Action fired when the user changes the color."),
};
const g_timeline = [_]rvn_schema_attribute_t{
    N("Duration", "Length of the sequence, in seconds."),
    N("Time", "Where the playhead is, in seconds."),
    N("FrameRate", "Frames per second: times snap to frames and show as seconds:frames; 0 = none."),
    B("Snapping", "Items snap to frames, to the playhead and to each other."),
    N("ViewStart", "First second shown."),
    N("ViewEnd", "Last second shown."),
    B("Loop", "Playing starts again at the end."),
    B("Playing", "The playhead runs."),
    N("HeaderWidth", "Width of the names of the tracks; 0 fits the longest."),
    N("TrackHeight", "Height of a track."),
    A("OnChanged", "Action fired when the user moves, stretches or removes something."),
};
const g_block_editor = [_]rvn_schema_attribute_t{
    N("Zoom", "Size of the canvas: 1 = life size."),
    B("Palette", "The column of blocks to drag from, on the left."),
    A("OnChanged", "Action fired when the user snaps, moves, edits or deletes blocks."),
};
const g_node_graph = [_]rvn_schema_attribute_t{
    N("Zoom", "Size of the canvas: 1 = life size."),
    N("CenterX", "What the middle of the widget shows, across the canvas."),
    N("CenterY", "What the middle of the widget shows, down the canvas."),
    B("Grid", "The dots of the canvas."),
    C("Flow", "Auto|true|false", "The pulses that run along the links: while the pointer is over the graph, always, or never."),
    B("ReadOnly", "The user can look, select and move the view, but not change the graph."),
    B("FrameAll", "Starts with every node in view."),
    A("OnChanged", "Action fired when the user links, unlinks, moves or removes something."),
};

const rvn_schema_tag_t = struct {
    tag: [*c]const u8,
    attributes: [*c]const rvn_schema_attribute_t,
    count: c_int,
    description: [*c]const u8,
};

inline fn TAG(tag: [*c]const u8, attributes: []const rvn_schema_attribute_t, description: [*c]const u8) rvn_schema_tag_t {
    return .{ .tag = tag, .attributes = attributes.ptr, .count = @intCast(attributes.len), .description = description };
}
inline fn TAG_PLAIN(tag: [*c]const u8, description: [*c]const u8) rvn_schema_tag_t {
    return .{ .tag = tag, .attributes = null, .count = 0, .description = description };
}

const g_tags = [_]rvn_schema_tag_t{
    TAG("Window", &g_window, "A window; it contains one element, and optionally an Island and Shortcut elements."),
    TAG("VBox", &g_box, "Stacks its children from top to bottom."),
    TAG("HBox", &g_box, "Lines its children up from left to right."),
    TAG("Grid", &g_grid, "Places its children in rows and columns (Slot.Column, Slot.Row)."),
    TAG("UniformGrid", &g_uniform_grid, "Cells of the same size, filled in order."),
    TAG_PLAIN("Overlay", "Puts its children on top of each other."),
    TAG("Border", &g_border, "A surface with padding around one child."),
    TAG("SizeBox", &g_size_box, "Gives one child a size or a shape."),
    TAG_PLAIN("Spacer", "Empty space."),
    TAG("ScrollBox", &g_scroll_box, "Scrolls content that is larger than its place."),
    TAG("Splitter", &g_splitter, "Panes separated by bars the user drags."),
    TAG("WrapBox", &g_box, "Lines its children up and continues on the next line."),
    TAG_PLAIN("Canvas", "Places its children freely (Slot.Position, Slot.Size, Slot.Anchors)."),
    TAG("Switcher", &g_switcher, "Shows one of its children."),
    TAG("TabView", &g_tab_view, "Its children as tabs (Slot.Title)."),
    TAG("Expander", &g_expander, "A header that shows and hides one child."),
    TAG("Label", &g_label, "Text."),
    TAG("Button", &g_button, "A button, with a text or with one child."),
    TAG("Checkbox", &g_checkbox, "A box to check, a radio button or a switch."),
    TAG("Slider", &g_slider, "A value chosen by dragging."),
    TAG("ProgressBar", &g_progress_bar, "How far something is."),
    TAG("Image", &g_image, "A picture."),
    TAG("TextInput", &g_text_input, "One line of text to type."),
    TAG("SpinBox", &g_spin_box, "A number to type or to step."),
    TAG("ComboBox", &g_combo_box, "One choice in a list that drops down."),
    TAG("Separator", &g_separator, "A line between things."),
    TAG("ListView", &g_list_view, "Rows of text, one selected; any number of them."),
    TAG("TreeView", &g_tree_view, "Rows inside rows, made of Item elements."),
    TAG("TileView", &g_tile_view, "A grid of tiles, an icon over a name, given by the application (Rtile_view_set_items)."),
    TAG_PLAIN("MenuBar", "A bar of Menu elements."),
    TAG("Menu", &g_menu, "A menu: MenuItem, Separator and Menu elements."),
    TAG("MenuItem", &g_menu_item, "An item of a menu."),
    TAG("Viewport", &g_viewport, "A place the application draws in with its own renderer."),
    TAG_PLAIN("Custom", "A widget painted and measured by the application."),
    TAG("TextEditor", &g_text_editor, "Text of several lines: notes, code."),
    TAG("HeaderBar", &g_header_bar, "The title bar of a window with a custom header; holds any widgets."),
    TAG("FileBrowser", &g_file_browser, "Folders and files to choose from."),
    TAG("DockArea", &g_dock_area, "Panels the user arranges by dragging their tabs."),
    TAG("Island", &g_island, "A pill at the top of the window that unfolds: first child folded, second unfolded."),
    TAG("BackgroundBlur", &g_background_blur, "A panel that shows what is behind it out of focus, around one child."),
    TAG("ColorPicker", &g_color_picker, "Chooses a color: square, hues, opacity, code, numbers, swatches."),
    TAG("Timeline", &g_timeline, "A sequencer: Track elements holding Clip and Key elements, and Marker elements."),
    TAG("BlockEditor", &g_block_editor, "Blocks that snap into each other (Scratch): Kind elements (Name, Label, Shape, Category) and Category elements (Name, Color)."),
    TAG("NodeGraph", &g_node_graph, "Nodes linked by wires: Node elements (Input, Output, any widget), Link and Type elements."),
};

fn rvn_schema_tag(tag: [*c]const u8) ?*const rvn_schema_tag_t {
    if (tag == null) return null;
    for (0..g_tags.len) |i| {
        if (base.rvn_stricmp(g_tags[i].tag, tag) == 0) return &g_tags[i];
    }
    // another name of a class ("TextBlock", "Notch")
    const cls = widget_h.rvn_widget_class_by_name(tag);
    if (cls == null) return null;
    for (0..g_tags.len) |i| {
        if (libc.strcmp(g_tags[i].tag, cls.*.name) == 0) return &g_tags[i];
    }
    return null;
}

fn rvn_schema_is_window(tag: *const rvn_schema_tag_t) c_int {
    return @intFromBool(tag == &g_tags[0]);
}

// ---------------------------------------------------------------------------
//  Public API
// ---------------------------------------------------------------------------

export fn Rxml_get_tag_count() c_int {
    return @intCast(g_tags.len);
}

export fn Rxml_get_tag_name(index: c_int) [*c]const u8 {
    if (index < 0 or index >= @as(c_int, @intCast(g_tags.len))) return null;
    return g_tags[@intCast(index)].tag;
}

export fn Rxml_get_tag_description(tag: [*c]const u8) [*c]const u8 {
    const entry = rvn_schema_tag(tag);
    return if (entry) |e| e.description else "";
}

export fn Rxml_get_tag_children(tag: [*c]const u8) c_int {
    const entry = rvn_schema_tag(tag) orelse return 2;
    if (rvn_schema_is_window(entry) != 0) return 1;
    const cls = widget_h.rvn_widget_class_by_name(entry.tag);
    if (cls == null) return 2;
    if ((cls.*.flags & widget_h.RVN_CF_NO_CHILDREN) != 0) return 0;
    return if ((cls.*.flags & widget_h.RVN_CF_SINGLE_CHILD) != 0) 1 else 2;
}

/// The parameters of a tag declared with <Widget>.
fn rvn_schema_parameter_count(tag: [*c]const u8) c_int {
    var count: c_int = 0;
    while (xml.rvn_xml_component_parameter(tag, count, null, null) != 0) count += 1;
    return count;
}

export fn Rxml_get_attribute_count(tag: [*c]const u8) c_int {
    const entry = rvn_schema_tag(tag);
    const shared: c_int = @intCast(g_widget.len + g_slot.len + g_colors.len + g_metrics.len);
    if (tag == null) return 0;
    if (entry) |e| return if (rvn_schema_is_window(e) != 0) e.count else e.count + shared;
    return rvn_schema_parameter_count(tag) + shared;
}

export fn Rxml_get_attribute_info(tag: [*c]const u8, index_in: c_int, info: [*c]raven.RXmlAttributeInfo) c_int {
    const shared = [_]struct { attributes: [*c]const rvn_schema_attribute_t, count: c_int, group: [*c]const u8 }{
        .{ .attributes = &g_widget, .count = @intCast(g_widget.len), .group = "Widget" },
        .{ .attributes = &g_slot, .count = @intCast(g_slot.len), .group = "Slot" },
        .{ .attributes = &g_colors, .count = @intCast(g_colors.len), .group = "Colors" },
        .{ .attributes = &g_metrics, .count = @intCast(g_metrics.len), .group = "Metrics" },
    };
    const entry = rvn_schema_tag(tag);
    var attribute: ?*const rvn_schema_attribute_t = null;
    var group: [*c]const u8 = null;
    var index = index_in;

    if (info != null) _ = libc.memset(info, 0, @sizeOf(raven.RXmlAttributeInfo));
    if (tag == null or info == null or index < 0) return raven.R_FALSE;
    if (entry) |e| {
        if (index < e.count) {
            attribute = &e.attributes[@intCast(index)];
            group = e.tag;
        } else if (rvn_schema_is_window(e) != 0) {
            return raven.R_FALSE;
        }
        index -= e.count;
    } else {
        var name: [*c]const u8 = undefined;
        var default_value: [*c]const u8 = undefined;
        if (xml.rvn_xml_component_parameter(tag, index, &name, &default_value) != 0) {
            info.*.name = name;
            info.*.type = raven.R_XML_TEXT;
            info.*.group = tag;
            info.*.description = default_value;
            return raven.R_TRUE;
        }
        index -= rvn_schema_parameter_count(tag);
    }
    var i: usize = 0;
    while (attribute == null and i < shared.len) : (i += 1) {
        if (index < shared[i].count) {
            attribute = &shared[i].attributes[@intCast(index)];
            group = shared[i].group;
        }
        index -= shared[i].count;
    }
    if (attribute == null) return raven.R_FALSE;
    const a = attribute.?;
    info.*.name = a.name;
    info.*.type = a.type;
    info.*.choices = a.choices;
    info.*.group = group;
    info.*.description = a.description;
    return raven.R_TRUE;
}
