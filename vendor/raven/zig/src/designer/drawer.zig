// Translated to Zig from vendor/raven/tools/designer/drawer.c (Raven, Apache-2.0). Modified by Seridian: C11 → Zig translation.
//
// Raven IDE - drawer.c
// The content drawer: the files of the project as tiles, in a panel that
// slides in from the left over the IDE. Ctrl+Space opens and closes it, from
// anywhere (also from the code editors); Escape, a click beside it, or a
// file opened closes it.
//
//   left     the folders of the project (a click shows one)
//   right    the tiles of the folder: folders first, then the files, an
//            icon by kind (interface, XML, code, build, translations,
//            pictures, text) and the extension in the corner
//   search   the whole project, by name; each tile says where the file is
//
// A double click (or Enter) on a folder goes into it, on a file opens it as
// the IDE does for any file (ide_open_file: an interface opens as code, the
// island shows it). A right click on an interface (.xml, .xmlc, .xmlpy...)
// offers its Preview: the visual editor. Up goes to the folder above, never
// above the project.

const std = @import("std");
const raven = @import("raven");
const ide = @import("ide_h.zig");
const libc = @import("../sys/libc.zig");

const MAX_TILES = 2000;
const ICON_SIZE = 96;

const kind_t = c_uint;
const KIND_FOLDER: c_int = 0;
const KIND_INTERFACE: c_int = 1;
const KIND_XML: c_int = 2;
const KIND_CODE: c_int = 3;
const KIND_BUILD: c_int = 4;
const KIND_STRINGS: c_int = 5;
const KIND_IMAGE: c_int = 6;
const KIND_TEXT: c_int = 7;
const KIND_COUNT: c_int = 8;

const tile_t = extern struct {
    name: [*c]u8,
    path: [*c]u8,
    detail: [*c]u8,
    badge: [12]u8,
    kind: kind_t,
};

const DRAWER_XML = "<Overlay Name=\"drawer.root\" Visibility=\"Collapsed\">" ++
    "  <Border Name=\"drawer.veil\" Background=\"#00000066\"/>" ++
    "  <Border Name=\"drawer\" Slot.HAlign=\"Left\" Width=\"780\" Shadow=\"30,8,0\" CornerRadius=\"0,14,14,0\" AccessibleRole=\"Dialog\" AccessibleName=\"Content drawer\">" ++
    "    <VBox>" ++
    "      <HBox Spacing=\"8\" Slot.Padding=\"16,12,12,10\">" ++
    "        <Label Text=\"Content\" TextSize=\"18\" Slot.VAlign=\"Center\" AccessibleRole=\"Heading\"/>" ++
    "        <Button Name=\"drawer.up\" Text=\"Up\" Style=\"Flat\" Tooltip=\"The folder above\" Slot.VAlign=\"Center\"/>" ++
    "        <Label Name=\"drawer.where\" Opacity=\"0.6\" Slot.VAlign=\"Center\" Slot.Fill=\"1\"/>" ++
    "        <TextInput Name=\"drawer.search\" Placeholder=\"Search the project\" Width=\"230\" AccessibleName=\"Search the project\"/>" ++
    "        <Button Name=\"drawer.close\" Text=\"Close\" Style=\"Flat\" Tooltip=\"Escape, or Ctrl+Space\"/>" ++
    "      </HBox>" ++
    "      <Separator/>" ++
    "      <HBox Slot.Fill=\"1\">" ++
    "        <TreeView Name=\"drawer.folders\" Width=\"220\" AccessibleName=\"Folders\"/>" ++
    "        <TileView Name=\"drawer.tiles\" Slot.Fill=\"1\" TileWidth=\"108\" TileHeight=\"112\" IconSize=\"60\" Spacing=\"6\" AccessibleName=\"Files\"/>" ++
    "      </HBox>" ++
    "      <Separator/>" ++
    "      <HBox Spacing=\"12\" Slot.Padding=\"16,7\">" ++
    "        <Label Name=\"drawer.count\" Opacity=\"0.7\" Slot.Fill=\"1\"/>" ++
    "        <Label Text=\"Double click opens  \xC2\xB7  Right click: Preview  \xC2\xB7  Esc or Ctrl+Space closes\" Opacity=\"0.5\"/>" ++
    "      </HBox>" ++
    "    </VBox>" ++
    "  </Border>" ++
    "</Overlay>";

// (the anonymous struct of g_d in the C)
const drawer_state_t = extern struct {
    root: raven.Rid,
    panel: raven.Rid,
    tiles: raven.Rid,
    folders: raven.Rid,
    search: raven.Rid,
    where: raven.Rid,
    count: raven.Rid,
    icons: [KIND_COUNT]raven.Rid,
    tiles_data: [MAX_TILES]tile_t,
    tile_count: c_int,
    truncated: c_int,
    /// the folder shown (when not searching)
    folder: [*c]u8,
    /// the paths behind the items of the folder tree
    folder_paths: [*c][*c]u8,
    folder_path_count: c_int,
    syncing: c_int,
    // the menu of a right click on a tile, and the tile it is for
    menu: raven.Rid,
    menu_open: raven.Rid,
    menu_preview: raven.Rid,
    menu_path: [*c]u8,
    menu_is_folder: c_int,
};

var g_d: drawer_state_t = init: {
    @setEvalBranchQuota(100000);
    var v = std.mem.zeroes(drawer_state_t);
    v.root = raven.R_INVALID_ID;
    break :init v;
};

// ---------------------------------------------------------------------------
//  Icons, drawn once
// -------------------------------------------------------------------------

const g_kind_colors = [KIND_COUNT]c_uint{
    0xF5B83D, // folder
    0x0A84FF, // interface with code (.xmlc, .xmlrs...)
    0x30B0A0, // XML
    0x34C759, // code
    0xAF52DE, // build (CMakeLists.txt, Cargo.toml...)
    0xFF9F0A, // translations (.csv)
    0xFF6482, // pictures
    0x8E8E93, // the rest
};

/// What the icon is at a point: 0 nothing, 1 the body, 2 a lighter part, 3 a line on the body.
fn icon_part(kind: kind_t, x: f32, y: f32) c_int {
    if (kind == KIND_FOLDER) {
        const tab: c_int = @intFromBool(x >= 14.0 and x <= 46.0 and y >= 18.0 and y <= 32.0);
        var body: c_int = @intFromBool(x >= 12.0 and x <= 84.0 and y >= 26.0 and y <= 80.0);
        // rounded corners of the body
        const cx: f32 = if (x < 18.0) 18.0 else (if (x > 78.0) 78.0 else x);
        const cy: f32 = if (y < 32.0) 32.0 else (if (y > 74.0) 74.0 else y);
        if (body != 0 and (x - cx) * (x - cx) + (y - cy) * (y - cy) > 36.0) body = 0;
        if (body != 0) return if (y < 36.0) 2 else 1;
        return if (tab != 0) 1 else 0;
    } else {
        const left: f32 = 22.0;
        const right: f32 = 74.0;
        const top: f32 = 10.0;
        const bottom: f32 = 86.0;
        const fold: f32 = 18.0;
        var cx: f32 = undefined;
        var cy: f32 = undefined;
        if (x < left or x > right or y < top or y > bottom) return 0;
        // the folded corner, top right
        if (x > right - fold and y < top + fold) return if ((x - (right - fold)) > (y - top)) 0 else 2;
        cx = if (x < left + 6.0) left + 6.0 else (if (x > right - 6.0) right - 6.0 else x);
        cy = if (y < top + 6.0) top + 6.0 else (if (y > bottom - 6.0) bottom - 6.0 else y);
        if ((x - cx) * (x - cx) + (y - cy) * (y - cy) > 36.0) return 0;
        // lines of text
        if (x >= 32.0 and x <= 64.0) {
            var i: c_int = 0;
            while (i < 4) : (i += 1) {
                const line: f32 = 42.0 + @as(f32, @floatFromInt(i)) * 10.0;
                if (y >= line - 1.6 and y <= line + 1.6 and (i < 3 or x <= 52.0)) return 3;
            }
        }
        return 1;
    }
}

fn make_icon(kind: kind_t) raven.Rid {
    const pixels: [*c]u8 = @ptrCast(libc.calloc(@as(usize, ICON_SIZE) * ICON_SIZE, 4));
    var base: [3]f32 = undefined;
    var light: [3]f32 = undefined;
    var x: c_int = undefined;
    var y: c_int = undefined;
    var sx: c_int = undefined;
    var sy: c_int = undefined;
    var texture: raven.Rid = undefined;
    base[0] = @as(f32, @floatFromInt((g_kind_colors[kind] >> 16) & 255)) / 255.0;
    base[1] = @as(f32, @floatFromInt((g_kind_colors[kind] >> 8) & 255)) / 255.0;
    base[2] = @as(f32, @floatFromInt(g_kind_colors[kind] & 255)) / 255.0;
    x = 0;
    while (x < 3) : (x += 1) light[@intCast(x)] = base[@intCast(x)] + (1.0 - base[@intCast(x)]) * 0.45;
    y = 0;
    while (y < ICON_SIZE) : (y += 1) {
        x = 0;
        while (x < ICON_SIZE) : (x += 1) {
            // four by four samples per pixel: smooth edges
            var r: f32 = 0.0;
            var g: f32 = 0.0;
            var b: f32 = 0.0;
            var a: f32 = 0.0;
            sy = 0;
            while (sy < 4) : (sy += 1) {
                sx = 0;
                while (sx < 4) : (sx += 1) {
                    const part = icon_part(kind, @as(f32, @floatFromInt(x)) + (@as(f32, @floatFromInt(sx)) + 0.5) / 4.0, @as(f32, @floatFromInt(y)) + (@as(f32, @floatFromInt(sy)) + 0.5) / 4.0);
                    const c: [*c]const f32 = if (part == 2) &light else &base;
                    const k: f32 = if (part == 3) 0.55 else 1.0;
                    if (part == 0) continue;
                    // (a line is the body, lightened)
                    r += if (part == 3) c[0] + (1.0 - c[0]) * k else c[0];
                    g += if (part == 3) c[1] + (1.0 - c[1]) * k else c[1];
                    b += if (part == 3) c[2] + (1.0 - c[2]) * k else c[2];
                    a += 1.0;
                }
            }
            if (a > 0.0) {
                const p: [*c]u8 = pixels + (@as(usize, @intCast(y)) * ICON_SIZE + @as(usize, @intCast(x))) * 4;
                p[0] = @intFromFloat(r / a * 255.0 + 0.5);
                p[1] = @intFromFloat(g / a * 255.0 + 0.5);
                p[2] = @intFromFloat(b / a * 255.0 + 0.5);
                p[3] = @intFromFloat(a / 16.0 * 255.0 + 0.5);
            }
        }
    }
    texture = raven.Rtexture_create_from_pixels(pixels, ICON_SIZE, ICON_SIZE);
    libc.free(pixels);
    return texture;
}

fn kind_of(name: [*c]const u8, is_dir: c_int) kind_t {
    const ext = ide.ide_extension(name);
    if (is_dir != 0) return KIND_FOLDER;
    if (ide.ide_interface_language(name) != null) return KIND_INTERFACE;
    if (libc.strcmp(ext, "xml") == 0) return KIND_XML;
    if (libc.strcmp(ext, "csv") == 0) return KIND_STRINGS;
    if (ide.ide_iequal(name, "CMakeLists.txt") != 0 or ide.ide_iequal(name, "Cargo.toml") != 0 or ide.ide_iequal(name, "go.mod") != 0 or ide.ide_iequal(name, "build.zig") != 0 or
        libc.strcmp(ext, "cmake") == 0 or libc.strcmp(ext, "csproj") == 0 or libc.strcmp(ext, "sln") == 0) return KIND_BUILD;
    if (libc.strcmp(ext, "png") == 0 or libc.strcmp(ext, "jpg") == 0 or libc.strcmp(ext, "jpeg") == 0 or libc.strcmp(ext, "bmp") == 0 or libc.strcmp(ext, "gif") == 0 or
        libc.strcmp(ext, "svg") == 0 or libc.strcmp(ext, "ico") == 0 or libc.strcmp(ext, "tga") == 0) return KIND_IMAGE;
    if (libc.strcmp(ext, "c") == 0 or libc.strcmp(ext, "h") == 0 or libc.strcmp(ext, "cpp") == 0 or libc.strcmp(ext, "hpp") == 0 or libc.strcmp(ext, "cc") == 0 or libc.strcmp(ext, "rs") == 0 or
        libc.strcmp(ext, "py") == 0 or libc.strcmp(ext, "go") == 0 or libc.strcmp(ext, "cs") == 0 or libc.strcmp(ext, "zig") == 0 or libc.strcmp(ext, "lua") == 0 or
        libc.strcmp(ext, "js") == 0 or libc.strcmp(ext, "ts") == 0 or libc.strcmp(ext, "glsl") == 0 or libc.strcmp(ext, "frag") == 0 or libc.strcmp(ext, "vert") == 0) return KIND_CODE;
    return KIND_TEXT;
}

// ---------------------------------------------------------------------------
//  The tiles
// -------------------------------------------------------------------------

fn skipped(name: [*c]const u8, is_dir: c_int) c_int {
    if (name[0] == '.') return raven.R_TRUE;
    return @intFromBool(is_dir != 0 and (ide.ide_iequal(name, "build") != 0 or libc.strncmp(name, "build-", 6) == 0 or ide.ide_iequal(name, "out") != 0 or ide.ide_iequal(name, "node_modules") != 0 or
        ide.ide_iequal(name, "CMakeFiles") != 0 or ide.ide_iequal(name, "target") != 0 or ide.ide_iequal(name, "zig-out") != 0 or ide.ide_iequal(name, "zig-cache") != 0));
}

fn clear_tiles() void {
    var i: c_int = 0;
    while (i < g_d.tile_count) : (i += 1) {
        libc.free(g_d.tiles_data[@intCast(i)].name);
        libc.free(g_d.tiles_data[@intCast(i)].path);
        libc.free(g_d.tiles_data[@intCast(i)].detail);
    }
    g_d.tile_count = 0;
    g_d.truncated = raven.R_FALSE;
}

fn add_tile(folder: [*c]const u8, name: [*c]const u8, is_dir: c_int, detail: [*c]const u8) void {
    var tile: [*c]tile_t = undefined;
    const ext = ide.ide_extension(name);
    var i: usize = undefined;
    if (g_d.tile_count >= MAX_TILES) {
        g_d.truncated = raven.R_TRUE;
        return;
    }
    tile = &g_d.tiles_data[@intCast(g_d.tile_count)];
    g_d.tile_count += 1;
    tile.*.name = ide.ide_strdup(name);
    tile.*.path = ide.ide_join(folder, name);
    tile.*.detail = if (detail != null) ide.ide_strdup(detail) else null;
    tile.*.kind = kind_of(name, is_dir);
    tile.*.badge[0] = 0;
    if (is_dir == 0 and ext[0] != 0) {
        i = 0;
        while (ext[i] != 0 and i + 1 < @sizeOf(@TypeOf(tile.*.badge))) : (i += 1) tile.*.badge[i] = std.ascii.toUpper(ext[i]);
        tile.*.badge[i] = 0;
    }
}

fn on_tile(tile_view: raven.Rid, index: c_int, item: [*c]raven.RTileItem, user_data: ?*anyopaque) callconv(.c) void {
    var tile: [*c]const tile_t = undefined;
    _ = tile_view;
    _ = user_data;
    if (index < 0 or index >= g_d.tile_count) return;
    tile = &g_d.tiles_data[@intCast(index)];
    item.*.text = tile.*.name;
    item.*.detail = tile.*.detail;
    item.*.badge = if (tile.*.badge[0] != 0) &tile.*.badge else null;
    item.*.icon = g_d.icons[tile.*.kind];
}

/// Where the drawer is, said the short way: the project, then the folders below.
fn show_where(text: [*c]const u8) void {
    raven.Rlabel_set_text(g_d.where, text);
}

fn show_count() void {
    var text: [96]u8 = undefined;
    if (ide.g_project_dir == null) {
        text[0] = 0;
    } else {
        _ = libc.snprintf(&text, text.len, "%d item%s%s", g_d.tile_count, @as([*c]const u8, if (g_d.tile_count == 1) "" else "s"), @as([*c]const u8, if (g_d.truncated != 0) " (the first ones)" else ""));
    }
    raven.Rlabel_set_text(g_d.count, &text);
}

fn relative(path: [*c]const u8, out: [*c]u8, size: usize) void {
    const root: usize = if (ide.g_project_dir != null) libc.strlen(ide.g_project_dir) else 0;
    if (ide.g_project_dir != null and libc.strncmp(path, ide.g_project_dir, root) == 0 and (path[root] == '/' or path[root] == '\\' or path[root] == 0)) {
        _ = libc.snprintf(out, size, "%s%s", ide.ide_basename(ide.g_project_dir), path + root);
    } else {
        _ = libc.snprintf(out, size, "%s", path);
    }
}

fn show_folder(folder: [*c]const u8) void {
    var entries: [*c]ide.ide_entry_t = null;
    var count: c_int = undefined;
    var i: c_int = undefined;
    var where: [600]u8 = undefined;
    clear_tiles();
    if (folder != @as([*c]const u8, g_d.folder)) {
        libc.free(g_d.folder);
        g_d.folder = ide.ide_strdup(folder);
    }
    count = ide.ide_list_dir(g_d.folder, &entries);
    i = 0;
    while (i < count) : (i += 1) {
        if (skipped(&entries[@intCast(i)].name, entries[@intCast(i)].is_dir) == 0) add_tile(g_d.folder, &entries[@intCast(i)].name, entries[@intCast(i)].is_dir, null);
    }
    libc.free(entries);
    raven.Rtile_view_set_items(g_d.tiles, g_d.tile_count, on_tile, null);
    raven.Rtile_view_set_empty_text(g_d.tiles, if (count < 0) "This folder cannot be read." else "This folder is empty.");
    relative(g_d.folder, &where, where.len);
    show_where(&where);
    raven.Rwidget_set_enabled(raven.Rwidget_find(g_d.root, "drawer.up"), @intFromBool(ide.g_project_dir != null and ide.ide_same_path(g_d.folder, ide.g_project_dir) == 0));
    show_count();
}

fn search_in(folder: [*c]const u8, needle: [*c]const u8, depth: c_int) void {
    var entries: [*c]ide.ide_entry_t = null;
    var count: c_int = undefined;
    var i: c_int = undefined;
    if (depth > 10 or g_d.truncated != 0) return;
    count = ide.ide_list_dir(folder, &entries);
    i = 0;
    while (i < count and g_d.truncated == 0) : (i += 1) {
        const name: [*c]const u8 = &entries[@intCast(i)].name;
        const n: usize = libc.strlen(needle);
        var k: usize = undefined;
        var found: c_int = 0;
        if (skipped(name, entries[@intCast(i)].is_dir) != 0) continue;
        // (the name contains the text, whatever the case)
        k = 0;
        while (found == 0 and name[k] != 0) : (k += 1) {
            var j: usize = 0;
            while (j < n and name[k + j] != 0 and std.ascii.toLower(name[k + j]) == std.ascii.toLower(needle[j])) : (j += 1) {}
            found = @intFromBool(j == n);
        }
        if (found != 0) {
            var where: [600]u8 = undefined;
            relative(folder, &where, where.len);
            add_tile(folder, name, entries[@intCast(i)].is_dir, &where);
        }
        if (entries[@intCast(i)].is_dir != 0) {
            const sub = ide.ide_join(folder, name);
            search_in(sub, needle, depth + 1);
            libc.free(sub);
        }
    }
    libc.free(entries);
}

fn show_search(needle: [*c]const u8) void {
    var text: [300]u8 = undefined;
    clear_tiles();
    if (ide.g_project_dir != null) search_in(ide.g_project_dir, needle, 0);
    raven.Rtile_view_set_items(g_d.tiles, g_d.tile_count, on_tile, null);
    raven.Rtile_view_set_empty_text(g_d.tiles, "Nothing of that name in the project.");
    _ = libc.snprintf(&text, text.len, "Search: \"%s\" in the whole project", needle);
    show_where(&text);
    show_count();
}

// ---------------------------------------------------------------------------
//  The folders
// -------------------------------------------------------------------------

fn forget_folders() void {
    var i: c_int = 0;
    while (i < g_d.folder_path_count) : (i += 1) libc.free(g_d.folder_paths[@intCast(i)]);
    libc.free(@ptrCast(g_d.folder_paths));
    g_d.folder_paths = null;
    g_d.folder_path_count = 0;
}

fn add_folder(parent: raven.Rid, path: [*c]const u8, name: [*c]const u8) raven.Rid {
    const item = raven.Rtree_view_add_item(g_d.folders, parent, name);
    const copy = ide.ide_strdup(path);
    g_d.folder_paths = @ptrCast(@alignCast(libc.realloc(@ptrCast(g_d.folder_paths), @sizeOf([*c]u8) * @as(usize, @intCast(g_d.folder_path_count + 1)))));
    g_d.folder_paths[@intCast(g_d.folder_path_count)] = copy;
    g_d.folder_path_count += 1;
    raven.Rtree_item_set_user_handle(item, copy);
    raven.Rtree_item_set_text_color(item, 0.96, 0.72, 0.24, 1.0);
    return item;
}

fn fill_folders(parent: raven.Rid, folder: [*c]const u8, depth: c_int) void {
    var entries: [*c]ide.ide_entry_t = null;
    var count: c_int = undefined;
    var i: c_int = undefined;
    if (depth > 6 or g_d.folder_path_count > 800) return;
    count = ide.ide_list_dir(folder, &entries);
    i = 0;
    while (i < count) : (i += 1) {
        var path: [*c]u8 = undefined;
        var item: raven.Rid = undefined;
        if (entries[@intCast(i)].is_dir == 0 or skipped(&entries[@intCast(i)].name, 1) != 0) continue;
        path = ide.ide_join(folder, &entries[@intCast(i)].name);
        item = add_folder(parent, path, &entries[@intCast(i)].name);
        raven.Rtree_item_set_expanded(item, @intFromBool(depth < 1));
        fill_folders(item, path, depth + 1);
        libc.free(path);
    }
    libc.free(entries);
}

fn refresh_folders() void {
    var root: raven.Rid = undefined;
    raven.Rtree_view_clear_items(g_d.folders);
    forget_folders();
    if (ide.g_project_dir == null) return;
    root = add_folder(raven.R_INVALID_ID, ide.g_project_dir, ide.ide_basename(ide.g_project_dir));
    raven.Rtree_item_set_expanded(root, raven.R_TRUE);
    fill_folders(root, ide.g_project_dir, 0);
}

fn select_folder_item(path: [*c]const u8) void {
    // (the C declares an unused `int i; (void)i;` here)
    // (the tree follows the tiles: the item of the folder shown, when there is one)
    g_d.syncing += 1;
    raven.Rtree_view_set_selected_item(g_d.folders, raven.R_INVALID_ID);
    {
        // walk the items: they keep their paths
        var stack: [256]raven.Rid = undefined;
        var top: c_int = 0;
        var n: c_int = undefined;
        n = raven.Rtree_view_get_item_count(g_d.folders) - 1;
        while (n >= 0 and top < 256) : (n -= 1) {
            stack[@intCast(top)] = raven.Rtree_view_get_item(g_d.folders, n);
            top += 1;
        }
        while (top > 0) {
            top -= 1;
            const item = stack[@intCast(top)];
            const item_path: [*c]const u8 = @ptrCast(raven.Rtree_item_get_user_handle(item));
            if (item_path != null and ide.ide_same_path(item_path, path) != 0) {
                raven.Rtree_view_set_selected_item(g_d.folders, item);
                raven.Rtree_view_scroll_to_item(g_d.folders, item);
                break;
            }
            n = raven.Rtree_item_get_child_count(item) - 1;
            while (n >= 0 and top < 256) : (n -= 1) {
                stack[@intCast(top)] = raven.Rtree_item_get_child(item, n);
                top += 1;
            }
        }
    }
    g_d.syncing -= 1;
}

fn go_to(folder: [*c]const u8) void {
    if (raven.Rtext_input_get_text(g_d.search)[0] != 0) {
        g_d.syncing += 1;
        raven.Rtext_input_set_text(g_d.search, "");
        g_d.syncing -= 1;
    }
    show_folder(folder);
    select_folder_item(folder);
}

// ---------------------------------------------------------------------------
//  Opening and closing
// -------------------------------------------------------------------------

export fn drawer_is_open() c_int {
    return @intFromBool(g_d.root != raven.R_INVALID_ID and raven.Rwidget_get_visibility(g_d.root) == raven.R_VISIBLE);
}

export fn drawer_close() void {
    if (drawer_is_open() == 0) return;
    raven.Rwidget_set_visibility(g_d.root, raven.R_COLLAPSED);
}

export fn drawer_open() void {
    var r: f32 = undefined;
    var gr: f32 = undefined;
    var b: f32 = undefined;
    var a: f32 = undefined;
    var color: [16]u8 = undefined;
    if (g_d.root == raven.R_INVALID_ID) return;
    // the surface of the window, whatever the theme is now
    raven.Rtheme_get_color(raven.R_COLOR_WINDOW, &r, &gr, &b, &a);
    _ = libc.snprintf(&color, color.len, "#%02X%02X%02X", @as(c_int, @intFromFloat(r * 255.0 + 0.5)), @as(c_int, @intFromFloat(gr * 255.0 + 0.5)), @as(c_int, @intFromFloat(b * 255.0 + 0.5)));
    _ = raven.Rwidget_set_attribute(g_d.panel, "Background", &color);

    refresh_folders();
    if (ide.g_project_dir == null) {
        clear_tiles();
        raven.Rtile_view_set_items(g_d.tiles, 0, on_tile, null);
        raven.Rtile_view_set_empty_text(g_d.tiles, "No project is open: Project > Open folder, or New project.");
        show_where("");
        show_count();
        raven.Rwidget_set_enabled(raven.Rwidget_find(g_d.root, "drawer.up"), raven.R_FALSE);
    } else {
        // back where it was, when that is still in the project
        const folder: [*c]const u8 = if (g_d.folder != null and ide.ide_is_dir(g_d.folder) != 0 and libc.strncmp(g_d.folder, ide.g_project_dir, libc.strlen(ide.g_project_dir)) == 0) g_d.folder else ide.g_project_dir;
        const copy = ide.ide_strdup(folder);
        go_to(copy);
        libc.free(copy);
    }
    raven.Rwidget_set_visibility(g_d.root, raven.R_VISIBLE);
    raven.Rwidget_play_transition(g_d.panel, raven.R_TRANSITION_FLY_RIGHT, 0.0);
    raven.Rwidget_focus(g_d.search);
}

export fn drawer_toggle() void {
    if (drawer_is_open() != 0) drawer_close() else drawer_open();
}

fn on_activated(tile_view: raven.Rid, index: c_int, user_data: ?*anyopaque) callconv(.c) void {
    var path: [*c]u8 = undefined;
    _ = tile_view;
    _ = user_data;
    if (index < 0 or index >= g_d.tile_count) return;
    path = ide.ide_strdup(g_d.tiles_data[@intCast(index)].path);
    if (g_d.tiles_data[@intCast(index)].kind == KIND_FOLDER) {
        go_to(path);
    } else {
        drawer_close();
        ide.ide_open_file(path, 0);
    }
    libc.free(path);
}

/// A right click on a tile: Open, and Preview for an interface.
fn on_tile_context(tile_view: raven.Rid, index: c_int, x: f32, y: f32, user_data: ?*anyopaque) callconv(.c) void {
    var tile: [*c]const tile_t = undefined;
    var interface: c_int = undefined;
    _ = tile_view;
    _ = user_data;
    if (index < 0 or index >= g_d.tile_count or g_d.menu == raven.R_INVALID_ID) return;
    tile = &g_d.tiles_data[@intCast(index)];
    libc.free(g_d.menu_path);
    g_d.menu_path = ide.ide_strdup(tile.*.path);
    g_d.menu_is_folder = @intFromBool(tile.*.kind == KIND_FOLDER);
    interface = @intFromBool(tile.*.kind == KIND_INTERFACE or tile.*.kind == KIND_XML);
    raven.Rwidget_set_enabled(g_d.menu_preview, interface);
    raven.Rwidget_set_visibility(g_d.menu_preview, if (g_d.menu_is_folder != 0) raven.R_COLLAPSED else raven.R_VISIBLE);
    raven.Rmenu_open(g_d.menu, ide.g_ide_window, x, y);
}

fn on_menu(item: raven.Rid, user_data: ?*anyopaque) callconv(.c) void {
    var path: [*c]u8 = undefined;
    _ = item;
    if (g_d.menu_path == null) return;
    path = ide.ide_strdup(g_d.menu_path);
    if (g_d.menu_is_folder != 0) {
        go_to(path);
    } else {
        drawer_close();
        if (libc.strcmp(@as([*c]const u8, @ptrCast(user_data)), "preview") == 0) ide.ide_preview_file(path) else ide.ide_open_file(path, 0);
    }
    libc.free(path);
}

fn on_folder(tree: raven.Rid, item: raven.Rid, user_data: ?*anyopaque) callconv(.c) void {
    var path: [*c]const u8 = undefined;
    _ = tree;
    _ = user_data;
    if (g_d.syncing != 0 or item == raven.R_INVALID_ID) return;
    path = @ptrCast(raven.Rtree_item_get_user_handle(item));
    if (path != null) {
        const copy = ide.ide_strdup(path);
        if (raven.Rtext_input_get_text(g_d.search)[0] != 0) {
            g_d.syncing += 1;
            raven.Rtext_input_set_text(g_d.search, "");
            g_d.syncing -= 1;
        }
        show_folder(copy);
        libc.free(copy);
    }
}

fn on_search(input: raven.Rid, text: [*c]const u8, user_data: ?*anyopaque) callconv(.c) void {
    _ = input;
    _ = user_data;
    if (g_d.syncing != 0 or ide.g_project_dir == null) return;
    if (text != null and text[0] != 0) {
        show_search(text);
    } else if (g_d.folder != null) show_folder(g_d.folder);
}

fn on_button(button: raven.Rid, user_data: ?*anyopaque) callconv(.c) void {
    const which: [*c]const u8 = @ptrCast(user_data);
    _ = button;
    if (libc.strcmp(which, "close") == 0) {
        drawer_close();
    } else if (libc.strcmp(which, "up") == 0 and g_d.folder != null and ide.g_project_dir != null and ide.ide_same_path(g_d.folder, ide.g_project_dir) == 0) {
        const up = ide.ide_strdup(g_d.folder);
        var slash = libc.strrchr(up, '/');
        const back = libc.strrchr(up, '\\');
        if (back > slash) slash = back;
        if (slash != null) {
            slash.* = 0;
            go_to(up);
        }
        libc.free(up);
    }
}

/// A click beside the drawer closes it.
fn on_veil(widget: raven.Rid, event: [*c]const raven.REvent, user_data: ?*anyopaque) callconv(.c) c_int {
    _ = widget;
    _ = user_data;
    if (event.*.type == raven.R_EVENT_MOUSE_DOWN) {
        drawer_close();
        return raven.R_TRUE;
    }
    return raven.R_FALSE;
}

/// Ctrl+Space from anywhere (before the widgets: the code editors take it for their proposals), Escape while it is open.
fn on_window_event(window: raven.Rid, event: [*c]const raven.REvent, user_data: ?*anyopaque) callconv(.c) c_int {
    _ = window;
    _ = user_data;
    if (event.*.type == raven.R_EVENT_KEY_DOWN and event.*.key == raven.R_KEY_SPACE and (event.*.modifiers & raven.R_MOD_CTRL) != 0 and (event.*.modifiers & (raven.R_MOD_ALT | raven.R_MOD_SHIFT)) == 0) {
        if (event.*.repeat == 0 and ide.g_ide_dialog == raven.R_INVALID_ID) drawer_toggle();
        return raven.R_TRUE;
    }
    // (the space that comes with Ctrl+Space is not typed)
    if (event.*.type == raven.R_EVENT_TEXT and event.*.codepoint == ' ' and (event.*.modifiers & raven.R_MOD_CTRL) != 0) return raven.R_TRUE;
    if (event.*.type == raven.R_EVENT_KEY_DOWN and event.*.key == raven.R_KEY_ESCAPE and drawer_is_open() != 0) {
        drawer_close();
        return raven.R_TRUE;
    }
    return raven.R_FALSE;
}

fn action_drawer(sender: raven.Rid, action: [*c]const u8, user_data: ?*anyopaque) callconv(.c) void {
    _ = sender;
    _ = user_data;
    _ = action;
    drawer_toggle();
}

export fn drawer_init(host: raven.Rid) void {
    var i: c_int = undefined;
    g_d = std.mem.zeroes(drawer_state_t);
    i = 0;
    while (i < KIND_COUNT) : (i += 1) g_d.icons[@intCast(i)] = raven.R_INVALID_ID;
    g_d.menu_preview = raven.R_INVALID_ID;
    g_d.menu_open = g_d.menu_preview;
    g_d.menu = g_d.menu_open;
    g_d.root = raven.Rwidget_create_from_xml(DRAWER_XML, DRAWER_XML.len);
    if (g_d.root == raven.R_INVALID_ID) return;
    _ = raven.Rwidget_add_child(host, g_d.root);
    g_d.panel = raven.Rwidget_find(g_d.root, "drawer");
    g_d.tiles = raven.Rwidget_find(g_d.root, "drawer.tiles");
    g_d.folders = raven.Rwidget_find(g_d.root, "drawer.folders");
    g_d.search = raven.Rwidget_find(g_d.root, "drawer.search");
    g_d.where = raven.Rwidget_find(g_d.root, "drawer.where");
    g_d.count = raven.Rwidget_find(g_d.root, "drawer.count");
    i = 0;
    while (i < KIND_COUNT) : (i += 1) g_d.icons[@intCast(i)] = make_icon(@intCast(i));
    raven.Rtile_view_set_activated_callback(g_d.tiles, on_activated, null);
    raven.Rtile_view_set_context_callback(g_d.tiles, on_tile_context, null);
    g_d.menu = raven.Rwidget_create(raven.R_WIDGET_MENU);
    g_d.menu_open = raven.Rmenu_add_item(g_d.menu, "Open");
    g_d.menu_preview = raven.Rmenu_add_item(g_d.menu, "Preview");
    raven.Rmenu_item_set_clicked_callback(g_d.menu_open, on_menu, @ptrCast(@constCast("open")));
    raven.Rmenu_item_set_clicked_callback(g_d.menu_preview, on_menu, @ptrCast(@constCast("preview")));
    raven.Rtree_view_set_selection_changed_callback(g_d.folders, on_folder, null);
    raven.Rtext_input_set_changed_callback(g_d.search, on_search, null);
    raven.Rbutton_set_clicked_callback(raven.Rwidget_find(g_d.root, "drawer.close"), on_button, @ptrCast(@constCast("close")));
    raven.Rbutton_set_clicked_callback(raven.Rwidget_find(g_d.root, "drawer.up"), on_button, @ptrCast(@constCast("up")));
    raven.Rwidget_set_event_callback(raven.Rwidget_find(g_d.root, "drawer.veil"), on_veil, null);
    raven.Rwindow_set_event_hook(ide.g_ide_window, on_window_event, null);
    raven.Raction_bind("drawer.toggle", action_drawer, null);
}

export fn drawer_shutdown() void {
    var i: c_int = undefined;
    clear_tiles();
    forget_folders();
    libc.free(g_d.folder);
    g_d.folder = null;
    libc.free(g_d.menu_path);
    g_d.menu_path = null;
    i = 0;
    while (i < KIND_COUNT) : (i += 1) {
        if (g_d.icons[@intCast(i)] != raven.R_INVALID_ID) raven.Rtexture_destroy(g_d.icons[@intCast(i)]);
        g_d.icons[@intCast(i)] = raven.R_INVALID_ID;
    }
}
