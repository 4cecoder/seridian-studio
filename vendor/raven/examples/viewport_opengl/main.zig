// Translated to Zig from vendor/raven/examples/viewport_opengl/main.c (Raven, Apache-2.0). Modified by Seridian: C11 → Zig translation.
//
// Raven example - viewport_opengl
// An OpenGL scene inside a Raven window, using the native child window of a
// viewport (mode 3 of raven_viewport.h).
//
// Raven itself renders with Vulkan. For any other graphics API, a viewport can
// own a real OS window (HWND / X11 Window) that Raven keeps exactly on the
// widget. The application creates its context or swapchain on that window
// and draws whenever it wants: OpenGL here, but Direct3D or a second Vulkan
// swapchain work the same way.
//
// What this mode cannot do: the OS draws the child window above the UI, so
// widgets cannot overlap the scene and the scene is not clipped by scroll
// boxes (Raven hides the child when the widget is hidden). To get OpenGL
// *under* the UI, render to a texture instead and give the pixels to Raven
// (Rtexture_update, or zero-copy with Rvulkan_texture_create_shared and
// GL_EXT_memory_object).
//
// The scene uses OpenGL 1.1 calls only, so that the example needs no loader.

const std = @import("std");
const builtin = @import("builtin");
const raven = @import("raven");
const example = @import("example");

pub const panic = example.panic;

// ---- what the example uses of <GL/gl.h> (no @cImport in Zig 0.18: declared by hand) ----
// GLAPIENTRY is APIENTRY (__stdcall) on Windows and empty elsewhere.
const GLAPIENTRY: std.builtin.CallingConvention = if (builtin.os.tag == .windows) .winapi else .c;
const GLenum = c_uint;
const GLbitfield = c_uint;
const GLint = c_int;
const GLsizei = c_int;
const GLubyte = u8;
const GLfloat = f32;
const GLclampf = f32;
const GLdouble = f64;
const GL_COLOR_BUFFER_BIT: GLbitfield = 0x00004000;
const GL_DEPTH_BUFFER_BIT: GLbitfield = 0x00000100;
const GL_DEPTH_TEST: GLenum = 0x0B71;
const GL_FRONT_AND_BACK: GLenum = 0x0408;
const GL_LINE: GLenum = 0x1B01;
const GL_FILL: GLenum = 0x1B02;
const GL_PROJECTION: GLenum = 0x1701;
const GL_MODELVIEW: GLenum = 0x1700;
const GL_QUADS: GLenum = 0x0007;
const GL_RENDERER: GLenum = 0x1F01;
extern "c" fn glViewport(x: GLint, y: GLint, width: GLsizei, height: GLsizei) callconv(GLAPIENTRY) void;
extern "c" fn glClearColor(red: GLclampf, green: GLclampf, blue: GLclampf, alpha: GLclampf) callconv(GLAPIENTRY) void;
extern "c" fn glClear(mask: GLbitfield) callconv(GLAPIENTRY) void;
extern "c" fn glEnable(cap: GLenum) callconv(GLAPIENTRY) void;
extern "c" fn glPolygonMode(face: GLenum, mode: GLenum) callconv(GLAPIENTRY) void;
extern "c" fn glMatrixMode(mode: GLenum) callconv(GLAPIENTRY) void;
extern "c" fn glLoadIdentity() callconv(GLAPIENTRY) void;
extern "c" fn glFrustum(left: GLdouble, right: GLdouble, bottom: GLdouble, top: GLdouble, near_val: GLdouble, far_val: GLdouble) callconv(GLAPIENTRY) void;
extern "c" fn glTranslatef(x: GLfloat, y: GLfloat, z: GLfloat) callconv(GLAPIENTRY) void;
extern "c" fn glRotatef(angle: GLfloat, x: GLfloat, y: GLfloat, z: GLfloat) callconv(GLAPIENTRY) void;
extern "c" fn glBegin(mode: GLenum) callconv(GLAPIENTRY) void;
extern "c" fn glEnd() callconv(GLAPIENTRY) void;
extern "c" fn glColor3fv(v: [*c]const GLfloat) callconv(GLAPIENTRY) void;
extern "c" fn glVertex3fv(v: [*c]const GLfloat) callconv(GLAPIENTRY) void;
extern "c" fn glGetString(name: GLenum) callconv(GLAPIENTRY) [*c]const GLubyte;

// ---------------------------------------------------------------------------
//  OpenGL context on a native window: the only platform-specific part
// -------------------------------------------------------------------------

// #if defined(_WIN32) ... #else /* X11 */ ... #endif: one of the two namespaces, chosen at compile time
// (the other one is not analysed).
const gl_platform = if (builtin.os.tag == .windows) struct {
    // ---- what the example uses of <windows.h> (wingdi.h, winuser.h), declared by hand ----
    const WORD = u16;
    const DWORD = c_ulong;
    const BYTE = u8;
    const WINBOOL = c_int;
    const HWND = ?*opaque {};
    const HDC = ?*opaque {};
    const HGLRC = ?*opaque {};
    const PIXELFORMATDESCRIPTOR = extern struct {
        nSize: WORD,
        nVersion: WORD,
        dwFlags: DWORD,
        iPixelType: BYTE,
        cColorBits: BYTE,
        cRedBits: BYTE,
        cRedShift: BYTE,
        cGreenBits: BYTE,
        cGreenShift: BYTE,
        cBlueBits: BYTE,
        cBlueShift: BYTE,
        cAlphaBits: BYTE,
        cAlphaShift: BYTE,
        cAccumBits: BYTE,
        cAccumRedBits: BYTE,
        cAccumGreenBits: BYTE,
        cAccumBlueBits: BYTE,
        cAccumAlphaBits: BYTE,
        cDepthBits: BYTE,
        cStencilBits: BYTE,
        cAuxBuffers: BYTE,
        iLayerType: BYTE,
        bReserved: BYTE,
        dwLayerMask: DWORD,
        dwVisibleMask: DWORD,
        dwDamageMask: DWORD,
    };
    const PFD_TYPE_RGBA: BYTE = 0;
    const PFD_DOUBLEBUFFER: DWORD = 0x00000001;
    const PFD_DRAW_TO_WINDOW: DWORD = 0x00000004;
    const PFD_SUPPORT_OPENGL: DWORD = 0x00000020;
    extern "user32" fn GetDC(hWnd: HWND) callconv(.winapi) HDC;
    extern "gdi32" fn ChoosePixelFormat(hdc: HDC, ppfd: [*c]const PIXELFORMATDESCRIPTOR) callconv(.winapi) c_int;
    extern "gdi32" fn SetPixelFormat(hdc: HDC, format: c_int, ppfd: [*c]const PIXELFORMATDESCRIPTOR) callconv(.winapi) WINBOOL;
    extern "gdi32" fn SwapBuffers(hdc: HDC) callconv(.winapi) WINBOOL;
    extern "opengl32" fn wglCreateContext(hdc: HDC) callconv(.winapi) HGLRC;
    extern "opengl32" fn wglDeleteContext(hglrc: HGLRC) callconv(.winapi) WINBOOL;
    extern "opengl32" fn wglMakeCurrent(hdc: HDC, hglrc: HGLRC) callconv(.winapi) WINBOOL;

    var g_dc: HDC = null;
    var g_context: HGLRC = null;

    fn gl_create(native: [*c]const raven.RNativeWindow) c_int {
        var descriptor: PIXELFORMATDESCRIPTOR = undefined;
        var format: c_int = undefined;

        @memset(std.mem.asBytes(&descriptor), 0);
        descriptor.nSize = @sizeOf(PIXELFORMATDESCRIPTOR);
        descriptor.nVersion = 1;
        descriptor.dwFlags = PFD_DRAW_TO_WINDOW | PFD_SUPPORT_OPENGL | PFD_DOUBLEBUFFER;
        descriptor.iPixelType = PFD_TYPE_RGBA;
        descriptor.cColorBits = 32;
        descriptor.cDepthBits = 24;

        // the child windows of Raven have their own device context (CS_OWNDC)
        g_dc = GetDC(@ptrFromInt(native.*.window));
        format = ChoosePixelFormat(g_dc, &descriptor);
        if (format == 0 or SetPixelFormat(g_dc, format, &descriptor) == 0) return 0;
        g_context = wglCreateContext(g_dc);
        return @intFromBool(g_context != null and wglMakeCurrent(g_dc, g_context) != 0);
    }

    fn gl_swap() void {
        _ = SwapBuffers(g_dc);
    }

    fn gl_destroy() void {
        _ = wglMakeCurrent(null, null);
        if (g_context != null) _ = wglDeleteContext(g_context);
        g_context = null;
    }
} else struct { // X11
    // ---- what the example uses of <X11/Xlib.h>, <X11/Xutil.h> and <GL/glx.h>, declared by hand ----
    const Display = opaque {};
    const Visual = opaque {};
    const Screen = opaque {};
    const XID = c_ulong;
    const VisualID = c_ulong;
    const Window = XID;
    const Colormap = XID;
    const GLXDrawable = XID;
    const Bool = c_int;
    const Status = c_int;
    const True: Bool = 1;
    const None: XID = 0;
    const VisualIDMask: c_long = 0x1;
    const XWindowAttributes = extern struct {
        x: c_int,
        y: c_int,
        width: c_int,
        height: c_int,
        border_width: c_int,
        depth: c_int,
        visual: ?*Visual,
        root: Window,
        class: c_int,
        bit_gravity: c_int,
        win_gravity: c_int,
        backing_store: c_int,
        backing_planes: c_ulong,
        backing_pixel: c_ulong,
        save_under: Bool,
        colormap: Colormap,
        map_installed: Bool,
        map_state: c_int,
        all_event_masks: c_long,
        your_event_mask: c_long,
        do_not_propagate_mask: c_long,
        override_redirect: Bool,
        screen: ?*Screen,
    };
    const XVisualInfo = extern struct {
        visual: ?*Visual,
        visualid: VisualID,
        screen: c_int,
        depth: c_int,
        class: c_int,
        red_mask: c_ulong,
        green_mask: c_ulong,
        blue_mask: c_ulong,
        colormap_size: c_int,
        bits_per_rgb: c_int,
    };
    const GLXContext = ?*opaque {};
    extern "c" fn XGetWindowAttributes(display: ?*Display, w: Window, window_attributes_return: [*c]XWindowAttributes) Status;
    extern "c" fn XVisualIDFromVisual(visual: ?*Visual) VisualID;
    extern "c" fn XGetVisualInfo(display: ?*Display, vinfo_mask: c_long, vinfo_template: [*c]XVisualInfo, nitems_return: [*c]c_int) [*c]XVisualInfo;
    extern "c" fn XFree(data: ?*anyopaque) c_int;
    extern "c" fn glXCreateContext(dpy: ?*Display, vis: [*c]XVisualInfo, shareList: GLXContext, direct: Bool) GLXContext;
    extern "c" fn glXDestroyContext(dpy: ?*Display, ctx: GLXContext) void;
    extern "c" fn glXMakeCurrent(dpy: ?*Display, drawable: GLXDrawable, ctx: GLXContext) Bool;
    extern "c" fn glXSwapBuffers(dpy: ?*Display, drawable: GLXDrawable) void;

    var g_display: ?*Display = null;
    var g_drawable: Window = 0;
    var g_context: GLXContext = null;

    fn gl_create(native: [*c]const raven.RNativeWindow) c_int {
        var attributes: XWindowAttributes = undefined;
        var wanted: XVisualInfo = undefined;
        var visual: [*c]XVisualInfo = undefined;
        var count: c_int = 0;

        g_display = @ptrCast(native.*.display);
        g_drawable = @intCast(native.*.window);

        // the context must use the visual the window was created with
        if (XGetWindowAttributes(g_display, g_drawable, &attributes) == 0) return 0;
        wanted.visualid = XVisualIDFromVisual(attributes.visual);
        visual = XGetVisualInfo(g_display, VisualIDMask, &wanted, &count);
        if (visual == null) return 0;
        g_context = glXCreateContext(g_display, visual, null, True);
        _ = XFree(visual);
        return @intFromBool(g_context != null and glXMakeCurrent(g_display, g_drawable, g_context) != 0);
    }

    fn gl_swap() void {
        glXSwapBuffers(g_display, g_drawable);
    }

    fn gl_destroy() void {
        if (g_display == null) return;
        _ = glXMakeCurrent(g_display, None, null);
        if (g_context != null) glXDestroyContext(g_display, g_context);
        g_context = null;
    }
};
const gl_create = gl_platform.gl_create;
const gl_swap = gl_platform.gl_swap;
const gl_destroy = gl_platform.gl_destroy;

// ---------------------------------------------------------------------------
//  Scene
// -------------------------------------------------------------------------

var app = std.mem.zeroes(struct {
    window: raven.Rid,
    viewport: raven.Rid,
    speed: raven.Rid,
    wireframe: raven.Rid,
    info: raven.Rid,
    context_ready: c_int,
    angle: f32,
});

fn scene_draw(width: c_int, height: c_int) void {
    const colors = [6][3]f32{
        .{ 1.0, 0.35, 0.2 }, .{ 0.25, 0.85, 0.4 }, .{ 0.25, 0.5, 1.0 },
        .{ 1.0, 0.8, 0.2 },  .{ 0.8, 0.3, 0.9 },   .{ 0.2, 0.85, 0.9 },
    };
    const faces = [6][4][3]f32{
        .{ .{ -1, -1, 1 }, .{ 1, -1, 1 }, .{ 1, 1, 1 }, .{ -1, 1, 1 } }, .{ .{ 1, -1, -1 }, .{ -1, -1, -1 }, .{ -1, 1, -1 }, .{ 1, 1, -1 } },
        .{ .{ -1, 1, 1 }, .{ 1, 1, 1 }, .{ 1, 1, -1 }, .{ -1, 1, -1 } }, .{ .{ -1, -1, -1 }, .{ 1, -1, -1 }, .{ 1, -1, 1 }, .{ -1, -1, 1 } },
        .{ .{ 1, -1, 1 }, .{ 1, -1, -1 }, .{ 1, 1, -1 }, .{ 1, 1, 1 } }, .{ .{ -1, -1, -1 }, .{ -1, -1, 1 }, .{ -1, 1, 1 }, .{ -1, 1, -1 } },
    };
    const aspect: f64 = @as(f64, @floatFromInt(width)) / @as(f64, @floatFromInt(height));
    var face: c_int = undefined;
    var corner: c_int = undefined;

    glViewport(0, 0, width, height);
    glClearColor(0.05, 0.06, 0.10, 1.0);
    glClear(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT);
    glEnable(GL_DEPTH_TEST);
    glPolygonMode(GL_FRONT_AND_BACK, if (raven.Rcheckbox_is_checked(app.wireframe) != 0) GL_LINE else GL_FILL);

    glMatrixMode(GL_PROJECTION);
    glLoadIdentity();
    glFrustum(-0.1 * aspect, 0.1 * aspect, -0.1, 0.1, 0.2, 20.0);
    glMatrixMode(GL_MODELVIEW);
    glLoadIdentity();
    glTranslatef(0.0, 0.0, -5.0);
    glRotatef(app.angle * 40.0, 0.3, 1.0, 0.2);

    glBegin(GL_QUADS);
    face = 0;
    while (face < 6) : (face += 1) {
        glColor3fv(&colors[@intCast(face)]);
        corner = 0;
        while (corner < 4) : (corner += 1) glVertex3fv(&faces[@intCast(face)][@intCast(corner)]);
    }
    glEnd();
}

/// Called once per frame.
fn on_frame(delta_seconds: f64, user_data: ?*anyopaque) callconv(.c) void {
    var width: c_int = 0;
    var height: c_int = 0;
    _ = user_data;
    if (app.context_ready == 0 or raven.Rwindow_is_valid(app.window) == 0) return;

    app.angle += @as(f32, @floatCast(delta_seconds)) * raven.Rslider_get_value(app.speed);
    // the child window has exactly the size of the widget, in pixels
    raven.Rviewport_get_pixel_size(app.viewport, &width, &height);
    if (width <= 0 or height <= 0) return;
    scene_draw(width, height);
    gl_swap();
}

const g_layout: [:0]const u8 =
    "<Window Title=\"Raven - OpenGL viewport\" Width=\"900\" Height=\"540\">" ++
    "  <HBox>" ++
    "    <VBox Width=\"240\" Spacing=\"10\" Slot.Padding=\"12\">" ++
    "      <Label TextSize=\"16\">OpenGL in a native viewport</Label>" ++
    "      <Label Wrap=\"true\" Opacity=\"0.7\">The cube is drawn by an OpenGL context created on a child window that Raven keeps on the viewport widget.</Label>" ++
    "      <Label>Speed</Label>" ++
    "      <Slider Name=\"speed\" Min=\"0\" Max=\"4\" Value=\"1\"/>" ++
    "      <Checkbox Name=\"wireframe\" Text=\"Wireframe\"/>" ++
    "      <Label Name=\"info\" Wrap=\"true\" Opacity=\"0.7\"/>" ++
    "    </VBox>" ++
    "    <Separator Orientation=\"Vertical\"/>" ++
    "    <Viewport Name=\"scene\" Slot.Fill=\"1\" Realtime=\"true\"/>" ++
    "  </HBox>" ++
    "</Window>";

export fn main() c_int {
    var native: raven.RNativeWindow = undefined;

    if (example.example_init("viewport_opengl") == 0) return 1;

    // sizeof(g_layout) - 1: the length without the terminating zero
    app.window = raven.Rwindow_create_from_xml(g_layout, g_layout.len);
    app.viewport = raven.Rwidget_find(app.window, "scene");
    app.speed = raven.Rwidget_find(app.window, "speed");
    app.wireframe = raven.Rwidget_find(app.window, "wireframe");
    app.info = raven.Rwidget_find(app.window, "info");

    // asks Raven for a child window on the viewport, then puts an OpenGL context on it
    @memset(std.mem.asBytes(&native), 0);
    if (raven.Rviewport_set_native(app.viewport, raven.R_TRUE) != 0 and raven.Rviewport_get_native_handle(app.viewport, &native) != 0 and gl_create(&native) != 0) {
        app.context_ready = 1;
        raven.Rlabel_set_text(app.info, @as([*c]const u8, @ptrCast(glGetString(GL_RENDERER))));
    } else {
        raven.Rlabel_set_text(app.info, "Cannot create an OpenGL context on the viewport.");
    }

    raven.Rset_frame_callback(on_frame, null);
    // the loop belongs to the application: Raven draws one frame per call,
    // and Rwait_frame sleeps until there is something to draw
    if (example.example_automated(app.window) == 0) {
        while (raven.Rwait_frame(-1.0) != 0) {}
    }

    // the context goes before the window it was created on
    raven.Rset_frame_callback(null, null);
    if (app.context_ready != 0) gl_destroy();
    raven.Rshutdown();
    return 0;
}
