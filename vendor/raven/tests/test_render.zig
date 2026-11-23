// Translated to Zig from vendor/raven/tests/test_render.c (Raven, Apache-2.0). Modified by Seridian: C11 → Zig translation.
//
// Raven tests - rendering with the Vulkan backend.
//
// Frames are rendered for real and read back with Rwindow_capture, then a
// few well-chosen pixels are compared with the expected colors. The test
// first tries to run without a window system (VK_EXT_headless_surface), then
// with a real window. Without a usable Vulkan driver it is skipped (exit
// code 77), so that the test suite still passes on machines without a GPU.

const std = @import("std");
const builtin = @import("builtin");
const raven = @import("raven");
const t = @import("test.zig");

pub const panic = t.panic;

// <stdlib.h>
extern "c" fn abs(x: c_int) c_int;
extern "c" fn getenv(name: [*c]const u8) [*c]u8;
// <unistd.h> (not on _WIN32)
extern "c" fn usleep(usec: c_uint) c_int;
extern "c" fn close(fd: c_int) c_int;

const SKIP_CODE = 77;

var g_pixels: [*c]u8 = null;
var g_width: c_int = 0;
var g_height: c_int = 0;
var g_scale: f32 = 1.0;

// Renders the window and keeps its pixels for the CHECK_PIXEL that follow.
fn capture(window: raven.Rid) void {
    raven.Rpixels_free(g_pixels);
    _ = raven.Rdraw_frame();
    g_pixels = raven.Rwindow_capture(window, &g_width, &g_height);
    g_scale = raven.Rwindow_get_scale(window);
    t.CHECK(@src(), g_pixels != null, "g_pixels != NULL");
}

fn pixel_at(x: f32, y: f32) [*c]const u8 {
    const S = struct {
        const none = [4]u8{ 0, 0, 0, 0 };
    };
    const px: c_int = @intFromFloat(x * g_scale);
    const py: c_int = @intFromFloat(y * g_scale);
    if (g_pixels == null or px < 0 or py < 0 or px >= g_width or py >= g_height) return &S.none;
    return g_pixels + (@as(usize, @intCast(py)) * @as(usize, @intCast(g_width)) + @as(usize, @intCast(px))) * 4;
}

/// Position in logical units, expected color, with a tolerance for rounding in the blending.
/// CHECK_PIXEL(x, y, er, eg, eb): the C macro takes the place of the check (__FILE__, __LINE__),
/// the caller passes @src().
fn CHECK_PIXEL(src: t.Src, x: f64, y: f64, er: c_int, eg: c_int, eb: c_int) void {
    const test_p_: [*c]const u8 = pixel_at(@floatCast(x), @floatCast(y));
    t.g_test_checks += 1;
    if ((abs(@as(c_int, test_p_[0]) - (er)) > 3 or abs(@as(c_int, test_p_[1]) - (eg)) > 3 or abs(@as(c_int, test_p_[2]) - (eb)) > 3)) {
        t.g_test_failures += 1;
        _ = t.printf("  FAIL %s:%d: pixel (%g, %g) = (%d, %d, %d), expected (%d, %d, %d)\n", src.file.ptr, @as(c_int, @intCast(src.line)), //
            x, y, @as(c_int, test_p_[0]), @as(c_int, test_p_[1]), @as(c_int, test_p_[2]), er, eg, eb);
    }
}

fn window_from(xml: [*c]const u8) raven.Rid {
    const window: raven.Rid = raven.Rwindow_create_from_xml(xml, t.strlen(xml));
    t.CHECK(@src(), raven.Rwindow_is_valid(window) != 0, "Rwindow_is_valid(window)");
    return window;
}

// ---------------------------------------------------------------------------
//  Tests
// -------------------------------------------------------------------------

fn test_shapes() void {
    const window: raven.Rid = window_from(
        "<Window Width=\"400\" Height=\"300\" ClearColor=\"#336699\">" ++
            "  <Canvas>" ++
            // plain rectangle
            "    <Border Slot.Position=\"10,10\" Slot.Size=\"100,60\" Background=\"#FF0000\" CornerRadius=\"0\" BorderWidth=\"0\"/>" ++
            // disc: a square with a radius of half its side
            "    <Border Slot.Position=\"150,10\" Slot.Size=\"100,100\" Background=\"#00FF00\" CornerRadius=\"50\" BorderWidth=\"0\"/>" ++
            // outline
            "    <Border Slot.Position=\"10,150\" Slot.Size=\"100,100\" Background=\"#000000\" CornerRadius=\"0\" BorderWidth=\"10\" BorderColor=\"#FFFFFF\"/>" ++
            // half-transparent white over black
            "    <Border Slot.Position=\"150,150\" Slot.Size=\"100,100\" Background=\"#000000\" CornerRadius=\"0\" BorderWidth=\"0\">" ++
            "      <Border Background=\"#FFFFFF\" Opacity=\"0.5\" CornerRadius=\"0\" BorderWidth=\"0\"/>" ++
            "    </Border>" ++
            "  </Canvas>" ++
            "</Window>",
    );
    capture(window);
    t.CHECK(@src(), g_width == @as(c_int, @intFromFloat(400 * g_scale)) and g_height == @as(c_int, @intFromFloat(300 * g_scale)), "g_width == (int)(400 * g_scale) && g_height == (int)(300 * g_scale)");

    // clear color
    CHECK_PIXEL(@src(), 390, 290, 0x33, 0x66, 0x99);
    CHECK_PIXEL(@src(), 5, 5, 0x33, 0x66, 0x99);
    // rectangle: inside, just inside each edge, just outside
    CHECK_PIXEL(@src(), 60, 40, 255, 0, 0);
    CHECK_PIXEL(@src(), 10.5, 10.5, 255, 0, 0);
    CHECK_PIXEL(@src(), 109.5, 69.5, 255, 0, 0);
    CHECK_PIXEL(@src(), 9.5, 40, 0x33, 0x66, 0x99);
    CHECK_PIXEL(@src(), 110.5, 40, 0x33, 0x66, 0x99);
    CHECK_PIXEL(@src(), 60, 70.5, 0x33, 0x66, 0x99);
    // disc: center filled, corners of its square untouched
    CHECK_PIXEL(@src(), 200, 60, 0, 255, 0);
    CHECK_PIXEL(@src(), 200, 12, 0, 255, 0);
    CHECK_PIXEL(@src(), 153, 13, 0x33, 0x66, 0x99);
    CHECK_PIXEL(@src(), 247, 107, 0x33, 0x66, 0x99);
    // outline: white band of 10 units, black inside
    CHECK_PIXEL(@src(), 15, 200, 255, 255, 255);
    CHECK_PIXEL(@src(), 60, 245, 255, 255, 255);
    CHECK_PIXEL(@src(), 60, 200, 0, 0, 0);
    CHECK_PIXEL(@src(), 22, 162, 0, 0, 0);
    // opacity
    CHECK_PIXEL(@src(), 200, 200, 128, 128, 128);

    raven.Rwindow_destroy(window);
}

fn test_clipping() void {
    // the red child is larger than its clipping parent: only the part inside is drawn
    const window: raven.Rid = window_from(
        "<Window Width=\"300\" Height=\"200\" ClearColor=\"#000000\">" ++
            "  <Canvas>" ++
            "    <Canvas Slot.Position=\"50,50\" Slot.Size=\"100,100\" Clip=\"true\">" ++
            "      <Border Slot.Position=\"-40,-40\" Slot.Size=\"300,300\" Background=\"#FF0000\" CornerRadius=\"0\" BorderWidth=\"0\"/>" ++
            "    </Canvas>" ++
            "  </Canvas>" ++
            "</Window>",
    );
    capture(window);
    CHECK_PIXEL(@src(), 100, 100, 255, 0, 0);
    CHECK_PIXEL(@src(), 51, 51, 255, 0, 0);
    CHECK_PIXEL(@src(), 149, 149, 255, 0, 0);
    CHECK_PIXEL(@src(), 49, 100, 0, 0, 0);
    CHECK_PIXEL(@src(), 151, 100, 0, 0, 0);
    CHECK_PIXEL(@src(), 100, 49, 0, 0, 0);
    CHECK_PIXEL(@src(), 100, 151, 0, 0, 0);
    CHECK_PIXEL(@src(), 20, 20, 0, 0, 0);
    raven.Rwindow_destroy(window);
}

fn test_textures() void {
    // 2 x 2 texels: red, green / blue, half-transparent white
    const texels = [16]u8{
        255, 0, 0,   255, 0,   255, 0,   255,
        0,   0, 255, 255, 255, 255, 255, 128,
    };
    const yellow = [16]u8{
        255, 255, 0, 255, 255, 255, 0, 255, 255, 255, 0, 255, 255, 255, 0, 255,
    };
    const window: raven.Rid = window_from(
        "<Window Width=\"300\" Height=\"200\" ClearColor=\"#000000\">" ++
            "  <Canvas><Image Name=\"image\" Slot.Position=\"20,20\" Slot.Size=\"100,100\"/></Canvas>" ++
            "</Window>",
    );
    const image: raven.Rid = raven.Rwidget_find(window, "image");
    const texture: raven.Rid = raven.Rtexture_create_from_pixels(&texels, 2, 2);
    var width: c_int = 0;
    var height: c_int = 0;

    t.CHECK(@src(), raven.Rtexture_is_valid(texture) != 0 and raven.Rtexture_is_ready(texture) != 0, "Rtexture_is_valid(texture) && Rtexture_is_ready(texture)");
    raven.Rtexture_get_size(texture, &width, &height);
    t.CHECK(@src(), width == 2 and height == 2, "width == 2 && height == 2");
    // no smoothing: each texel is a flat quarter of the image
    raven.Rtexture_set_filter(texture, raven.R_FILTER_NEAREST);
    raven.Rimage_set_texture(image, texture);
    raven.Rimage_set_stretch(image, raven.R_STRETCH_FILL);
    capture(window);
    CHECK_PIXEL(@src(), 45, 45, 255, 0, 0);
    CHECK_PIXEL(@src(), 95, 45, 0, 255, 0);
    CHECK_PIXEL(@src(), 45, 95, 0, 0, 255);
    // the alpha of the texture blends with what is behind (black)
    CHECK_PIXEL(@src(), 95, 95, 128, 128, 128);
    CHECK_PIXEL(@src(), 130, 60, 0, 0, 0);

    // the tint multiplies the texture
    raven.Rimage_set_tint_color(image, 1.0, 0.0, 0.0, 1.0);
    capture(window);
    CHECK_PIXEL(@src(), 45, 45, 255, 0, 0);
    CHECK_PIXEL(@src(), 95, 45, 0, 0, 0);
    raven.Rimage_set_tint_color(image, 1.0, 1.0, 1.0, 1.0);

    // new pixels, same size
    raven.Rtexture_update(texture, &yellow, 2, 2);
    capture(window);
    CHECK_PIXEL(@src(), 45, 45, 255, 255, 0);
    CHECK_PIXEL(@src(), 95, 95, 255, 255, 0);

    // a deleted texture is simply not drawn
    raven.Rtexture_destroy(texture);
    t.CHECK(@src(), raven.Rtexture_is_valid(texture) == 0, "!Rtexture_is_valid(texture)");
    capture(window);
    CHECK_PIXEL(@src(), 45, 45, 0, 0, 0);

    raven.Rwindow_destroy(window);
}

fn test_text() void {
    const window: raven.Rid = window_from(
        "<Window Width=\"300\" Height=\"120\" ClearColor=\"#000000\">" ++
            "  <Canvas><Label Name=\"label\" Slot.Position=\"20,20\" TextSize=\"40\" Color=\"#FFFFFF\">Raven</Label></Canvas>" ++
            "</Window>",
    );
    var x: f32 = undefined;
    var y: f32 = undefined;
    var w: f32 = undefined;
    var h: f32 = undefined;
    var lit_inside: c_int = 0;
    var lit_outside: c_int = 0;
    var px: c_int = undefined;
    var py: c_int = undefined;

    capture(window);
    raven.Rwidget_get_rect(raven.Rwidget_find(window, "label"), &x, &y, &w, &h);
    t.CHECK(@src(), w > 40 and h > 30, "w > 40 && h > 30");
    py = 0;
    while (py < g_height) : (py += 1) {
        px = 0;
        while (px < g_width) : (px += 1) {
            const p: [*c]const u8 = g_pixels + (@as(usize, @intCast(py)) * @as(usize, @intCast(g_width)) + @as(usize, @intCast(px))) * 4;
            const lx: f32 = @as(f32, @floatFromInt(px)) / g_scale;
            const ly: f32 = @as(f32, @floatFromInt(py)) / g_scale;
            const inside: c_int = @intFromBool(lx >= x - 1 and ly >= y - 1 and lx < x + w + 1 and ly < y + h + 1);
            if (p[0] > 128) {
                if (inside != 0) {
                    lit_inside += 1;
                } else lit_outside += 1;
            }
        }
    }
    // three capital letters of 40 units cover a few hundred pixels, all inside the label
    t.CHECK(@src(), lit_inside > 300, "lit_inside > 300");
    t.CHECK(@src(), lit_outside == 0, "lit_outside == 0");
    raven.Rwindow_destroy(window);
}

fn paint_custom(widget: raven.Rid, painter: ?*raven.RPainter, width: f32, height: f32, user_data: ?*anyopaque) callconv(.c) void {
    _ = widget;
    _ = width;
    _ = height;
    _ = user_data;
    raven.Rdraw_triangle(painter, 10, 10, 90, 10, 50, 90, 1, 0, 0, 1);
    raven.Rdraw_line(painter, 110, 50, 190, 50, 10, 0, 1, 0, 1);
    raven.Rdraw_circle(painter, 250, 50, 40, 0, 0, 1, 1);
    raven.Rdraw_rect_outline(painter, 10, 110, 80, 60, 0, 4, 1, 1, 1, 1);
    raven.Rdraw_push_clip_rect(painter, 110, 110, 40, 60);
    raven.Rdraw_rect(painter, 110, 110, 80, 60, 0, 1, 1, 0, 1);
    raven.Rdraw_pop_clip_rect(painter);
}

fn test_custom_drawing() void {
    const window: raven.Rid = window_from(
        "<Window Width=\"300\" Height=\"200\" ClearColor=\"#000000\"><Custom Name=\"custom\"/></Window>",
    );
    raven.Rcustom_set_paint_callback(raven.Rwidget_find(window, "custom"), paint_custom, null);
    capture(window);
    // triangle
    CHECK_PIXEL(@src(), 50, 30, 255, 0, 0);
    CHECK_PIXEL(@src(), 50, 80, 255, 0, 0);
    CHECK_PIXEL(@src(), 15, 80, 0, 0, 0);
    CHECK_PIXEL(@src(), 85, 80, 0, 0, 0);
    // line of thickness 10 with round caps
    CHECK_PIXEL(@src(), 150, 50, 0, 255, 0);
    CHECK_PIXEL(@src(), 150, 46, 0, 255, 0);
    CHECK_PIXEL(@src(), 150, 58, 0, 0, 0);
    // circle
    CHECK_PIXEL(@src(), 250, 50, 0, 0, 255);
    CHECK_PIXEL(@src(), 250, 15, 0, 0, 255);
    CHECK_PIXEL(@src(), 215, 15, 0, 0, 0);
    // outline
    CHECK_PIXEL(@src(), 12, 140, 255, 255, 255);
    CHECK_PIXEL(@src(), 50, 140, 0, 0, 0);
    // clip rectangle: only the left half of the yellow rectangle
    CHECK_PIXEL(@src(), 130, 140, 255, 255, 0);
    CHECK_PIXEL(@src(), 170, 140, 0, 0, 0);
    raven.Rwindow_destroy(window);
}

fn paint_glass(widget: raven.Rid, painter: ?*raven.RPainter, width: f32, height: f32, user_data: ?*anyopaque) callconv(.c) void {
    _ = widget;
    _ = width;
    _ = height;
    _ = user_data;
    // clear glass: no tint
    raven.Rdraw_glass(painter, 100, 50, 200, 100, 20, 0, 0, 0, 0);
}

fn test_glass() void {
    // a slab of glass lies across the border between a red and a blue half
    const window: raven.Rid = window_from(
        "<Window Width=\"400\" Height=\"200\" ClearColor=\"#000000\">" ++
            "  <Overlay>" ++
            "    <Canvas>" ++
            "      <Border Slot.Position=\"0,0\" Slot.Size=\"200,200\" Background=\"#FF0000\" CornerRadius=\"0\" BorderWidth=\"0\"/>" ++
            "      <Border Slot.Position=\"200,0\" Slot.Size=\"200,200\" Background=\"#0000FF\" CornerRadius=\"0\" BorderWidth=\"0\"/>" ++
            "    </Canvas>" ++
            "    <Custom Name=\"glass\"/>" ++
            "  </Overlay>" ++
            "</Window>",
    );
    const custom: raven.Rid = raven.Rwidget_find(window, "glass");
    var p: [*c]const u8 = undefined;

    raven.Rcustom_set_paint_callback(custom, paint_glass, null);
    capture(window);

    // what is not under the glass is untouched, and the border stays sharp there
    CHECK_PIXEL(@src(), 20, 100, 255, 0, 0);
    CHECK_PIXEL(@src(), 380, 100, 0, 0, 255);
    CHECK_PIXEL(@src(), 198, 20, 255, 0, 0);
    CHECK_PIXEL(@src(), 202, 20, 0, 0, 255);
    CHECK_PIXEL(@src(), 198, 180, 255, 0, 0);
    CHECK_PIXEL(@src(), 202, 180, 0, 0, 255);
    CHECK_PIXEL(@src(), 130, 47, 255, 0, 0);

    // under the glass the border is frosted: both colors on both sides of it
    p = pixel_at(197, 100);
    t.CHECK(@src(), p[0] > 50 and p[2] > 50 and p[1] < 40, "p[0] > 50 && p[2] > 50 && p[1] < 40");
    p = pixel_at(203, 100);
    t.CHECK(@src(), p[0] > 50 and p[2] > 50 and p[1] < 40, "p[0] > 50 && p[2] > 50 && p[1] < 40");
    // red wins on the left, blue on the right
    p = pixel_at(185, 100);
    t.CHECK(@src(), p[0] > p[2], "p[0] > p[2]");
    p = pixel_at(215, 100);
    t.CHECK(@src(), p[2] > p[0], "p[2] > p[0]");
    // far from the border, the flat middle of the slab shows the color behind it
    p = pixel_at(130, 100);
    t.CHECK(@src(), p[0] > 235 and p[1] < 25 and p[2] < 25, "p[0] > 235 && p[1] < 25 && p[2] < 25");
    p = pixel_at(270, 100);
    t.CHECK(@src(), p[2] > 235 and p[0] < 25 and p[1] < 25, "p[2] > 235 && p[0] < 25 && p[1] < 25");
    // the rim catches the light: a bright line on the upper edge
    p = pixel_at(130, 50.5);
    t.CHECK(@src(), p[1] > 40, "p[1] > 40");

    // without the glass, the frame is drawn straight to the window again
    raven.Rwidget_set_visibility(custom, raven.R_HIDDEN);
    capture(window);
    CHECK_PIXEL(@src(), 198, 100, 255, 0, 0);
    CHECK_PIXEL(@src(), 202, 100, 0, 0, 255);
    CHECK_PIXEL(@src(), 130, 50.5, 255, 0, 0);

    // ... and with it again
    raven.Rwidget_set_visibility(custom, raven.R_VISIBLE);
    capture(window);
    p = pixel_at(200, 100);
    t.CHECK(@src(), p[0] > 50 and p[2] > 50, "p[0] > 50 && p[2] > 50");

    raven.Rwindow_destroy(window);
}

fn test_glass_theme() void {
    var window: raven.Rid = undefined;
    var p: [*c]const u8 = undefined;

    // every control is glass, and the window gets a wallpaper for it to show
    raven.Rtheme_apply(raven.R_THEME_GLASS_DARK);
    window = window_from(
        "<Window Width=\"420\" Height=\"320\">" ++
            "  <Overlay>" ++
            "    <VBox Spacing=\"10\" Slot.Padding=\"20\">" ++
            "      <HBox Spacing=\"8\"><Button Text=\"Glass\"/><Button Text=\"Tinted\" Style=\"Primary\"/>" ++
            "        <Checkbox Text=\"Switch\" Style=\"Switch\" Checked=\"true\"/></HBox>" ++
            "      <Slider Value=\"0.5\"/>" ++
            "      <TextInput Placeholder=\"Text\"/>" ++
            "      <ComboBox Selected=\"0\"><Item Text=\"One\"/><Item Text=\"Two\"/></ComboBox>" ++
            "      <TabView Slot.Fill=\"1\"><Label Slot.Title=\"First\">Page</Label><Label Slot.Title=\"Second\">Other</Label></TabView>" ++
            "    </VBox>" ++
            "    <Border Name=\"panel\" Material=\"Glass\" Width=\"160\" Height=\"90\" Slot.HAlign=\"Right\" Slot.VAlign=\"Bottom\" Slot.Padding=\"12\"/>" ++
            "  </Overlay>" ++
            "</Window>",
    );
    capture(window);
    t.CHECK(@src(), g_width == @as(c_int, @intFromFloat(420 * g_scale)) and g_height == @as(c_int, @intFromFloat(320 * g_scale)), "g_width == (int)(420 * g_scale) && g_height == (int)(320 * g_scale)");

    // the background of the dark glass is a plain grey (#2A2A2E): no colors behind the glass
    p = pixel_at(4, 4);
    t.CHECK(@src(), abs(@as(c_int, p[0]) - 0x2A) < 8 and abs(@as(c_int, p[1]) - 0x2A) < 8 and abs(@as(c_int, p[2]) - 0x2E) < 8, "abs((int)p[0] - 0x2A) < 8 && abs((int)p[1] - 0x2A) < 8 && abs((int)p[2] - 0x2E) < 8");
    p = pixel_at(410, 6);
    t.CHECK(@src(), abs(@as(c_int, p[0]) - 0x2A) < 8 and abs(@as(c_int, p[1]) - 0x2A) < 8 and abs(@as(c_int, p[2]) - 0x2E) < 8, "abs((int)p[0] - 0x2A) < 8 && abs((int)p[1] - 0x2A) < 8 && abs((int)p[2] - 0x2E) < 8");

    // a second frame of the same window: the offscreen images are reused
    raven.Rwidget_invalidate(raven.Rwidget_find(window, "panel"));
    capture(window);
    t.CHECK(@src(), g_pixels != null, "g_pixels != NULL");

    // the same window with a flat theme, then with the light glass
    raven.Rtheme_apply(raven.R_THEME_DARK);
    capture(window);
    t.CHECK(@src(), g_pixels != null, "g_pixels != NULL");
    raven.Rtheme_apply(raven.R_THEME_GLASS_LIGHT);
    capture(window);
    t.CHECK(@src(), g_pixels != null, "g_pixels != NULL");

    raven.Rwindow_destroy(window);
    raven.Rtheme_apply(raven.R_THEME_DARK);
}

// How much a row of pixels changes from one pixel to the next: sharp edges give a high value.
fn row_contrast(x0: f32, x1: f32, y: f32) c_int {
    var total: c_int = 0;
    var x: f32 = undefined;
    x = x0;
    while (x + 1.0 < x1) : (x += 1.0) {
        const a: [*c]const u8 = pixel_at(x, y);
        const c: [*c]const u8 = pixel_at(x + 1.0, y);
        const r: c_int = a[0];
        const g: c_int = a[1];
        const b: c_int = a[2];
        total += abs(r - c[0]) + abs(g - c[1]) + abs(b - c[2]);
    }
    return total;
}

fn test_materials() void {
    // four panels over the same stripes: each material lets them through in its own way
    const window: raven.Rid = window_from(
        "<Window Width=\"440\" Height=\"120\" ClearColor=\"#000000\">" ++
            "  <Overlay>" ++
            "    <HBox Name=\"stripes\"/>" ++
            "    <HBox Slot.Padding=\"10,30\" Spacing=\"20\">" ++
            "      <Border Name=\"solid\" Material=\"Solid\" Width=\"90\" CornerRadius=\"0\" Background=\"#202020\"/>" ++
            "      <Border Name=\"clear\" Material=\"Glass\" Width=\"90\" CornerRadius=\"0\" Background=\"#20202040\"/>" ++
            "      <Border Name=\"frosted\" Material=\"FrostedGlass\" Width=\"90\" CornerRadius=\"0\" Background=\"#20202040\"/>" ++
            "      <VBox Name=\"tinted\" Material=\"TintedGlass\" Width=\"90\"/>" ++
            "    </HBox>" ++
            "  </Overlay>" ++
            "</Window>",
    );
    const stripes: raven.Rid = raven.Rwidget_find(window, "stripes");
    var stats: raven.RFrameStats = undefined;
    var p: [*c]const u8 = undefined;
    var i: c_int = undefined;
    var behind: c_int = undefined;
    var solid: c_int = undefined;
    var clear: c_int = undefined;
    var frosted: c_int = undefined;

    i = 0;
    while (i < 44) : (i += 1) {
        const stripe: raven.Rid = raven.Rwidget_add_child(stripes, raven.Rwidget_create(raven.R_WIDGET_BORDER));
        raven.Rwidget_set_size(stripe, 10.0, -1.0);
        raven.Rborder_set_background(stripe, if ((i & 1) != 0) 1.0 else 0.0, if ((i & 1) != 0) 1.0 else 0.0, if ((i & 1) != 0) 1.0 else 0.0, 1.0);
    }
    t.CHECK(@src(), raven.Rwidget_get_material(raven.Rwidget_find(window, "solid")) == raven.R_MATERIAL_SOLID, "Rwidget_get_material(Rwidget_find(window, \"solid\")) == R_MATERIAL_SOLID");
    t.CHECK(@src(), raven.Rwidget_get_material(raven.Rwidget_find(window, "clear")) == raven.R_MATERIAL_GLASS, "Rwidget_get_material(Rwidget_find(window, \"clear\")) == R_MATERIAL_GLASS");
    t.CHECK(@src(), raven.Rwidget_get_material(raven.Rwidget_find(window, "tinted")) == raven.R_MATERIAL_TINTED_GLASS, "Rwidget_get_material(Rwidget_find(window, \"tinted\")) == R_MATERIAL_TINTED_GLASS");
    t.CHECK(@src(), raven.Rwidget_get_material(stripes) == raven.R_MATERIAL_SOLID, "Rwidget_get_material(stripes) == R_MATERIAL_SOLID");
    capture(window);
    raven.Rwindow_get_frame_stats(window, &stats);
    // the theme is flat, and yet three widgets are glass
    t.CHECK(@src(), stats.backdrop_count >= 1, "stats.backdrop_count >= 1");

    behind = row_contrast(15.0, 95.0, 10.0);
    solid = row_contrast(15.0, 95.0, 60.0);
    clear = row_contrast(125.0, 205.0, 60.0);
    frosted = row_contrast(235.0, 315.0, 60.0);
    t.CHECK(@src(), behind > 2000, "behind > 2000");
    // solid hides the stripes, clear glass keeps them readable, frosted glass melts them
    t.CHECK(@src(), solid < 50, "solid < 50");
    t.CHECK(@src(), clear > frosted * 2, "clear > frosted * 2");
    t.CHECK(@src(), clear > @divTrunc(behind, 6), "clear > behind / 6");
    t.CHECK(@src(), frosted < @divTrunc(behind, 4), "frosted < behind / 4");
    // the widget that draws nothing by itself became a panel, colored by the accent: more blue than red
    p = pixel_at(390, 60);
    t.CHECK(@src(), @as(c_int, p[2]) > @as(c_int, p[0]) + 20, "p[2] > p[0] + 20");

    // the material of the theme is the one of every widget that has none
    raven.Rwidget_set_material(raven.Rwidget_find(window, "solid"), raven.R_MATERIAL_DEFAULT);
    t.CHECK(@src(), raven.Rwidget_get_material(raven.Rwidget_find(window, "solid")) == raven.R_MATERIAL_SOLID, "Rwidget_get_material(Rwidget_find(window, \"solid\")) == R_MATERIAL_SOLID");
    raven.Rtheme_set_material(raven.R_MATERIAL_FROSTED_GLASS);
    t.CHECK(@src(), raven.Rtheme_get_material() == raven.R_MATERIAL_FROSTED_GLASS, "Rtheme_get_material() == R_MATERIAL_FROSTED_GLASS");
    t.CHECK(@src(), raven.Rwidget_get_material(raven.Rwidget_find(window, "solid")) == raven.R_MATERIAL_FROSTED_GLASS, "Rwidget_get_material(Rwidget_find(window, \"solid\")) == R_MATERIAL_FROSTED_GLASS");
    t.CHECK(@src(), raven.Rwidget_get_material(raven.Rwidget_find(window, "clear")) == raven.R_MATERIAL_GLASS, "Rwidget_get_material(Rwidget_find(window, \"clear\")) == R_MATERIAL_GLASS");
    capture(window);
    t.CHECK(@src(), row_contrast(15.0, 95.0, 60.0) > 50, "row_contrast(15.0f, 95.0f, 60.0f) > 50");
    raven.Rtheme_apply(raven.R_THEME_DARK);
    t.CHECK(@src(), raven.Rtheme_get_material() == raven.R_MATERIAL_SOLID, "Rtheme_get_material() == R_MATERIAL_SOLID");

    t.EXPECT_ERRORS_BEGIN();
    raven.Rtheme_set_material(raven.R_MATERIAL_DEFAULT);
    raven.Rwidget_set_material(stripes, @as(raven.RMaterial, 7));
    t.EXPECT_ERRORS_END(@src(), 2, "g_test_errors >= (2)");
    raven.Rwindow_destroy(window);
}

fn paint_curves(widget: raven.Rid, painter: ?*raven.RPainter, width: f32, height: f32, user_data: ?*anyopaque) callconv(.c) void {
    _ = widget;
    _ = width;
    _ = height;
    _ = user_data;
    // a straight one, then one that bends from the top left to the bottom right
    raven.Rdraw_curve(painter, 20, 30, 70, 30, 130, 30, 180, 30, 8, 1, 0, 0, 1);
    raven.Rdraw_curve(painter, 20, 80, 100, 80, 100, 160, 180, 160, 6, 0, 1, 0, 1);
}

fn test_curves_and_blur() void {
    var window: raven.Rid = window_from(
        "<Window Width=\"200\" Height=\"200\" ClearColor=\"#000000\"><Custom Name=\"custom\"/></Window>",
    );
    var stripes: raven.Rid = undefined;
    var i: c_int = undefined;
    var behind: c_int = undefined;
    var plain: c_int = undefined;
    var frosted: c_int = undefined;

    raven.Rcustom_set_paint_callback(raven.Rwidget_find(window, "custom"), paint_curves, null);
    capture(window);
    // the straight curve: its middle, its thickness, its round ends
    CHECK_PIXEL(@src(), 100, 30, 255, 0, 0);
    CHECK_PIXEL(@src(), 100, 33, 255, 0, 0);
    CHECK_PIXEL(@src(), 100, 38, 0, 0, 0);
    CHECK_PIXEL(@src(), 18, 30, 255, 0, 0);
    CHECK_PIXEL(@src(), 12, 30, 0, 0, 0);
    // the bent one passes through its ends and its middle, and leaves the corners of its box alone
    CHECK_PIXEL(@src(), 25, 80, 0, 255, 0);
    CHECK_PIXEL(@src(), 100, 120, 0, 255, 0);
    CHECK_PIXEL(@src(), 175, 160, 0, 255, 0);
    CHECK_PIXEL(@src(), 170, 90, 0, 0, 0);
    CHECK_PIXEL(@src(), 30, 150, 0, 0, 0);
    raven.Rwindow_destroy(window);

    // a panel that blurs what is behind it: the stripes melt under it
    window = window_from(
        "<Window Width=\"320\" Height=\"120\" ClearColor=\"#000000\">" ++
            "  <Overlay>" ++
            "    <HBox Name=\"stripes\"/>" ++
            "    <HBox Slot.Padding=\"10,30\" Spacing=\"20\">" ++
            "      <BackgroundBlur Name=\"plain\" Style=\"Plain\" Radius=\"16\" Width=\"130\" CornerRadius=\"0\"/>" ++
            "      <BackgroundBlur Name=\"frosted\" Style=\"Frosted\" Radius=\"16\" Width=\"130\" CornerRadius=\"0\" Grain=\"0\"/>" ++
            "    </HBox>" ++
            "  </Overlay>" ++
            "</Window>",
    );
    stripes = raven.Rwidget_find(window, "stripes");
    i = 0;
    while (i < 32) : (i += 1) {
        const stripe: raven.Rid = raven.Rwidget_add_child(stripes, raven.Rwidget_create(raven.R_WIDGET_BORDER));
        raven.Rwidget_set_size(stripe, 10.0, -1.0);
        raven.Rborder_set_background(stripe, if ((i & 1) != 0) 1.0 else 0.0, if ((i & 1) != 0) 1.0 else 0.0, if ((i & 1) != 0) 1.0 else 0.0, 1.0);
    }
    capture(window);
    behind = row_contrast(20.0, 130.0, 10.0);
    plain = row_contrast(20.0, 130.0, 60.0);
    frosted = row_contrast(170.0, 280.0, 60.0);
    t.CHECK(@src(), behind > 2000, "behind > 2000");
    t.CHECK(@src(), plain < @divTrunc(behind, 5), "plain < behind / 5");
    t.CHECK(@src(), frosted < @divTrunc(behind, 5), "frosted < behind / 5");
    // blurred, not hidden: half white, half black gives a gray
    {
        const p: [*c]const u8 = pixel_at(75, 60);
        t.CHECK(@src(), p[0] > 60 and p[0] < 200, "p[0] > 60 && p[0] < 200");
    }
    raven.Rwindow_destroy(window);
}

fn test_node_graph() void {
    const window: raven.Rid = window_from(
        "<Window Width=\"520\" Height=\"220\" ClearColor=\"#000000\">" ++
            "  <NodeGraph Name=\"g\" Grid=\"false\" Flow=\"false\" Color.Input=\"#000000\">" ++
            "    <Type Name=\"signal\" Color=\"#00FF00\"/>" ++
            "    <Node Name=\"a\" Title=\"A\" X=\"30\" Y=\"40\" Color=\"#FF0000\"><Output Name=\"o\" Label=\"Out\" Type=\"signal\"/></Node>" ++
            "    <Node Name=\"b\" Title=\"B\" X=\"330\" Y=\"40\" Color=\"#0000FF\"><Input Name=\"i\" Label=\"In\" Type=\"signal\"/></Node>" ++
            "    <Link From=\"a.o\" To=\"b.i\"/>" ++
            "  </NodeGraph>" ++
            "</Window>",
    );
    const graph: raven.Rid = raven.Rwidget_find(window, "g");
    var ax: f32 = undefined;
    var ay: f32 = undefined;
    var bx: f32 = undefined;
    var by: f32 = undefined;
    var w: f32 = undefined;
    var h: f32 = undefined;
    var p: [*c]const u8 = undefined;
    var y: c_int = undefined;
    var found: c_int = 0;

    capture(window);
    raven.Rnode_graph_get_node_size(graph, raven.Rnode_graph_find_node(graph, "a"), &w, &h);
    // the headers wear the colors of their nodes
    p = pixel_at(30.0 + w - 20.0, 40.0 + 15.0);
    t.CHECK(@src(), p[0] > 150 and p[1] < 90 and p[2] < 90, "p[0] > 150 && p[1] < 90 && p[2] < 90");
    p = pixel_at(330.0 + w - 20.0, 40.0 + 15.0);
    t.CHECK(@src(), p[2] > 150 and p[0] < 90 and p[1] < 110, "p[2] > 150 && p[0] < 90 && p[1] < 110");
    // the canvas between the nodes is empty, except for the wire: it has the color of its type and hangs a little under the straight line
    raven.Rnode_graph_get_pin_position(graph, raven.Rnode_graph_find_pin(graph, raven.Rnode_graph_find_node(graph, "a"), "o"), &ax, &ay);
    raven.Rnode_graph_get_pin_position(graph, raven.Rnode_graph_find_pin(graph, raven.Rnode_graph_find_node(graph, "b"), "i"), &bx, &by);
    t.CHECK(@src(), ay == by and bx > ax + 100.0, "ay == by && bx > ax + 100.0f");
    y = @as(c_int, @intFromFloat(ay)) - 2;
    while (y < @as(c_int, @intFromFloat(ay)) + 26 and found == 0) : (y += 1) {
        p = pixel_at((ax + bx) * 0.5, @floatFromInt(y));
        if (p[1] > 200 and p[0] < 120 and p[2] < 120) found = y;
    }
    t.CHECK(@src(), found > @as(c_int, @intFromFloat(ay)), "found > (int)ay");
    p = pixel_at((ax + bx) * 0.5, ay - 30.0);
    t.CHECK(@src(), p[0] < 12 and p[1] < 12 and p[2] < 12, "p[0] < 12 && p[1] < 12 && p[2] < 12");
    p = pixel_at((ax + bx) * 0.5, ay + 60.0);
    t.CHECK(@src(), p[0] < 12 and p[1] < 12 and p[2] < 12, "p[0] < 12 && p[1] < 12 && p[2] < 12");
    // the pins are dots of that color on the edges
    p = pixel_at(ax, ay);
    t.CHECK(@src(), p[1] > 180 and p[0] < 140, "p[1] > 180 && p[0] < 140");

    // zoomed out around the middle, everything is twice as close to it
    raven.Rnode_graph_set_view(graph, 260.0, 110.0, 0.5);
    capture(window);
    p = pixel_at(260.0 + (30.0 + w - 20.0 - 260.0) * 0.5, 110.0 + (40.0 + 15.0 - 110.0) * 0.5);
    t.CHECK(@src(), p[0] > 150 and p[1] < 90 and p[2] < 90, "p[0] > 150 && p[1] < 90 && p[2] < 90");
    p = pixel_at(30.0 + w - 20.0, 40.0 + 15.0);
    t.CHECK(@src(), p[0] < 12 and p[1] < 12 and p[2] < 12, "p[0] < 12 && p[1] < 12 && p[2] < 12");
    raven.Rwindow_destroy(window);
}

var g_callback_calls: c_int = 0;
var g_callback_info: raven.RViewportDrawInfo = std.mem.zeroes(raven.RViewportDrawInfo);

// Render thread.
fn on_viewport_draw(info: [*c]const raven.RViewportDrawInfo, user_data: ?*anyopaque) callconv(.c) void {
    _ = user_data;
    g_callback_info = info.*;
    g_callback_calls += 1;
}

fn test_viewport() void {
    const S = struct {
        var pixels: [8 * 8 * 4]u8 = std.mem.zeroes([8 * 8 * 4]u8);
    };
    const window: raven.Rid = window_from(
        "<Window Width=\"300\" Height=\"200\" ClearColor=\"#000000\">" ++
            "  <Canvas>" ++
            "    <Viewport Name=\"texture\" Slot.Position=\"10,10\" Slot.Size=\"100,100\"/>" ++
            "    <Viewport Name=\"callback\" Slot.Position=\"150,20\" Slot.Size=\"120,80\"/>" ++
            "  </Canvas>" ++
            "</Window>",
    );
    const texture_viewport: raven.Rid = raven.Rwidget_find(window, "texture");
    var texture: raven.Rid = undefined;
    var width: c_int = 0;
    var height: c_int = 0;
    var i: c_int = undefined;

    // texture mode
    i = 0;
    while (i < 64) : (i += 1) {
        S.pixels[@intCast(i * 4 + 0)] = 0;
        S.pixels[@intCast(i * 4 + 1)] = 200;
        S.pixels[@intCast(i * 4 + 2)] = 100;
        S.pixels[@intCast(i * 4 + 3)] = 255;
    }
    texture = raven.Rtexture_create_from_pixels(&S.pixels, 8, 8);
    raven.Rviewport_set_texture(texture_viewport, texture);
    // callback mode
    raven.Rviewport_set_draw_callback(raven.Rwidget_find(window, "callback"), on_viewport_draw, null);

    capture(window);
    CHECK_PIXEL(@src(), 60, 60, 0, 200, 100);
    CHECK_PIXEL(@src(), 120, 60, 0, 0, 0);
    raven.Rviewport_get_pixel_size(texture_viewport, &width, &height);
    t.CHECK(@src(), width == @as(c_int, @intFromFloat(100 * g_scale)) and height == @as(c_int, @intFromFloat(100 * g_scale)), "width == (int)(100 * g_scale) && height == (int)(100 * g_scale)");

    // the capture waited for the frame, so the callback already ran on the render thread
    t.CHECK(@src(), g_callback_calls > 0, "g_callback_calls > 0");
    t.CHECK(@src(), g_callback_info.backend == raven.R_BACKEND_VULKAN, "g_callback_info.backend == R_BACKEND_VULKAN");
    t.CHECK(@src(), g_callback_info.window == window, "g_callback_info.window == window");
    t.CHECK(@src(), g_callback_info.command_buffer != null and g_callback_info.render_pass != null, "g_callback_info.command_buffer != NULL && g_callback_info.render_pass != NULL");
    t.CHECK(@src(), g_callback_info.x == @as(c_int, @intFromFloat(150 * g_scale)) and g_callback_info.y == @as(c_int, @intFromFloat(20 * g_scale)), "g_callback_info.x == (int)(150 * g_scale) && g_callback_info.y == (int)(20 * g_scale)");
    t.CHECK(@src(), g_callback_info.width == @as(c_int, @intFromFloat(120 * g_scale)) and g_callback_info.height == @as(c_int, @intFromFloat(80 * g_scale)), "g_callback_info.width == (int)(120 * g_scale) && g_callback_info.height == (int)(80 * g_scale)");
    t.CHECK(@src(), g_callback_info.clip_width == g_callback_info.width, "g_callback_info.clip_width == g_callback_info.width");

    raven.Rtexture_destroy(texture);
    raven.Rwindow_destroy(window);
}

fn test_windows() void {
    const first: raven.Rid = window_from("<Window Width=\"200\" Height=\"100\" ClearColor=\"#FF0000\"/>");
    const second: raven.Rid = window_from("<Window Width=\"120\" Height=\"160\" ClearColor=\"#0000FF\"/>");
    var i: c_int = undefined;

    // each window has its own swapchain
    capture(second);
    {
        // the window system may make a window larger than asked (Windows has a minimum width): the swapchain follows the window
        var fw: c_int = 0;
        var fh: c_int = 0;
        raven.Rwindow_get_framebuffer_size(second, &fw, &fh);
        t.CHECK(@src(), g_width == fw and g_height == fh, "g_width == fw && g_height == fh");
        t.CHECK(@src(), g_width >= @as(c_int, @intFromFloat(120 * g_scale)) and g_height >= @as(c_int, @intFromFloat(160 * g_scale)), "g_width >= (int)(120 * g_scale) && g_height >= (int)(160 * g_scale)");
    }
    CHECK_PIXEL(@src(), 60, 80, 0, 0, 255);
    capture(first);
    CHECK_PIXEL(@src(), 100, 50, 255, 0, 0);

    // resizing recreates the swapchain; a real window system confirms the size with an event
    raven.Rwindow_set_size(first, 260, 140);
    i = 0;
    while (i < 50) : (i += 1) {
        var width: c_int = 0;
        var height: c_int = 0;
        raven.Rpoll_events();
        _ = raven.Rdraw_frame();
        raven.Rwindow_get_size(first, &width, &height);
        if (width == 260 and height == 140) break;
        if (builtin.os.tag != .windows) {
            _ = usleep(10000);
        }
    }
    capture(first);
    t.CHECK(@src(), g_width == @as(c_int, @intFromFloat(260 * g_scale)) and g_height == @as(c_int, @intFromFloat(140 * g_scale)), "g_width == (int)(260 * g_scale) && g_height == (int)(140 * g_scale)");
    CHECK_PIXEL(@src(), 250, 130, 255, 0, 0);

    raven.Rwindow_set_clear_color(first, 0.0, 1.0, 0.0, 1.0);
    capture(first);
    CHECK_PIXEL(@src(), 10, 10, 0, 255, 0);

    raven.Rwindow_destroy(second);
    capture(first);
    CHECK_PIXEL(@src(), 10, 10, 0, 255, 0);
    raven.Rwindow_destroy(first);
}

fn test_vulkan_api() void {
    var count: raven.Ruint = 0;
    var names: [*c]const [*c]const u8 = undefined;
    var shared: raven.Rid = undefined;

    t.CHECK(@src(), raven.Rvulkan_get_instance() != null, "Rvulkan_get_instance() != NULL");
    t.CHECK(@src(), raven.Rvulkan_get_physical_device() != null, "Rvulkan_get_physical_device() != NULL");
    t.CHECK(@src(), raven.Rvulkan_get_device() != null, "Rvulkan_get_device() != NULL");
    t.CHECK(@src(), raven.Rvulkan_get_graphics_queue() != null, "Rvulkan_get_graphics_queue() != NULL");
    names = raven.Rvulkan_get_required_instance_extensions(&count);
    t.CHECK(@src(), names != null and count >= 2 and t.strcmp(names[0], "VK_KHR_surface") == 0, "names != NULL && count >= 2 && strcmp(names[0], \"VK_KHR_surface\") == 0");
    names = raven.Rvulkan_get_required_device_extensions(&count);
    t.CHECK(@src(), names != null and count == 1 and t.strcmp(names[0], "VK_KHR_swapchain") == 0, "names != NULL && count == 1 && strcmp(names[0], \"VK_KHR_swapchain\") == 0");

    // optional feature: not every device can export memory
    t.EXPECT_ERRORS_BEGIN();
    shared = raven.Rvulkan_texture_create_shared(64, 32);
    t.EXPECT_ERRORS_END(@src(), 0, "g_test_errors >= (0)");
    if (shared != raven.R_INVALID_ID) {
        var info: raven.RSharedTextureInfo = undefined;
        info = std.mem.zeroes(raven.RSharedTextureInfo);
        t.CHECK(@src(), raven.Rvulkan_texture_get_shared_info(shared, &info) != 0, "Rvulkan_texture_get_shared_info(shared, &info)");
        t.CHECK(@src(), info.width == 64 and info.height == 32, "info.width == 64 && info.height == 32");
        t.CHECK(@src(), info.allocation_size >= 64 * 32 * 4, "info.allocation_size >= 64 * 32 * 4");
        if (builtin.os.tag != .windows) {
            t.CHECK(@src(), info.handle >= 0, "info.handle >= 0");
            if (info.handle >= 0) _ = close(@truncate(info.handle));
        }
        raven.Rtexture_destroy(shared);
        _ = t.printf("  shared textures: supported\n");
    } else {
        _ = t.printf("  shared textures: not supported by this device\n");
    }
}

// ---------------------------------------------------------------------------
//  Start-up
// -------------------------------------------------------------------------

// Starts the Vulkan backend and checks that a window can really be rendered.
fn start(headless: c_int) c_int {
    var desc: raven.RInitDesc = undefined;
    var probe: raven.Rid = undefined;
    var pixels: [*c]u8 = undefined;
    var width: c_int = 0;
    var height: c_int = 0;

    desc = std.mem.zeroes(raven.RInitDesc);
    desc.backend = raven.R_BACKEND_VULKAN;
    desc.headless = headless;
    desc.app_name = "test_render";
    raven.Rerror_set_callback(t.test_error_callback);
    if (raven.Rinit_ex(&desc) == 0) return 0;
    probe = raven.Rwindow_create("probe", 64, 64, raven.R_WINDOW_DEFAULT);
    pixels = if (probe != raven.R_INVALID_ID) raven.Rwindow_capture(probe, &width, &height) else null;
    raven.Rpixels_free(pixels);
    if (probe != raven.R_INVALID_ID) raven.Rwindow_destroy(probe);
    if (pixels == null) {
        raven.Rshutdown();
        return 0;
    }
    // pixels are compared right after a change: no animation in between
    raven.Rset_animations_enabled(raven.R_FALSE);
    return 1;
}

export fn main() c_int {
    // failures to start are expected on machines without Vulkan: stay quiet
    // RAVEN_TEST_WINDOWED=1 forces a real window, to test the window system path too
    const windowed: c_int = @intFromBool(getenv("RAVEN_TEST_WINDOWED") != null);
    t.EXPECT_ERRORS_BEGIN();
    if (windowed == 0 and start(raven.R_TRUE) != 0) {
        _ = t.printf("test_render: Vulkan without a window system (headless surface)\n");
    } else if (start(raven.R_FALSE) != 0) {
        _ = t.printf("test_render: Vulkan with a real window\n");
    } else {
        _ = t.printf("test_render: SKIPPED, no usable Vulkan driver or display\n");
        return SKIP_CODE;
    }
    t.g_test_expect_errors = 0;
    t.g_test_checks = 0;
    t.g_test_failures = 0;

    t.RUN(test_shapes, "test_shapes");
    t.RUN(test_clipping, "test_clipping");
    t.RUN(test_textures, "test_textures");
    t.RUN(test_text, "test_text");
    t.RUN(test_custom_drawing, "test_custom_drawing");
    t.RUN(test_glass, "test_glass");
    t.RUN(test_glass_theme, "test_glass_theme");
    t.RUN(test_materials, "test_materials");
    t.RUN(test_curves_and_blur, "test_curves_and_blur");
    t.RUN(test_node_graph, "test_node_graph");
    t.RUN(test_viewport, "test_viewport");
    t.RUN(test_windows, "test_windows");
    t.RUN(test_vulkan_api, "test_vulkan_api");

    raven.Rpixels_free(g_pixels);
    raven.Rshutdown();
    return t.test_report("test_render");
}
