// Translated to Zig from vendor/raven/src/render/shader.c (Raven, Apache-2.0). Modified by Seridian: C11 → Zig translation.
//
// Raven - render/shader.c
// Effects: fragment shaders of the application and the built-in ones, and
// how a painter draws them (raven_shader.h).
//
// A shader is a handle on the UI thread; its SPIR-V goes to the backend
// through the render thread (CreateShader). Drawing one appends a SHADER
// instance to an R_DRAW_SHADER command that names it; the backend runs it
// with the inputs and bindings of the UI shader (raven_effect.glsl).

const std = @import("std");
const raven = @import("raven");
const base = @import("../core/base_h.zig");
const ctx = @import("../core/context_h.zig");
const handle = @import("../core/handle_h.zig");
const renderer = @import("renderer_h.zig");
const draw = @import("draw_h.zig");
const libc = @import("../sys/libc.zig");
const effect_aurora = @import("vulkan/generated/effect_aurora_spv.zig");
const effect_shimmer = @import("vulkan/generated/effect_shimmer_spv.zig");
const effect_neon = @import("vulkan/generated/effect_neon_spv.zig");
const effect_ripple = @import("vulkan/generated/effect_ripple_spv.zig");
const effect_plasma = @import("vulkan/generated/effect_plasma_spv.zig");
const effect_grain = @import("vulkan/generated/effect_grain_spv.zig");
const effect_spotlight = @import("vulkan/generated/effect_spotlight_spv.zig");
const effect_mesh = @import("vulkan/generated/effect_mesh_spv.zig");

// #define RVN_EFFECT_COUNT ((int)(R_EFFECT_LAST_ - R_EFFECT_AURORA))
const RVN_EFFECT_COUNT: c_int = raven.R_EFFECT_LAST_ - raven.R_EFFECT_AURORA;

// The flag and primitive constants of raven.zig are c_int / c_uint; the flags of a C
// `unsigned` expression are u32 here. Same values.
const R_SHADER_BACKDROP: u32 = @intCast(raven.R_SHADER_BACKDROP);
const R_SHADER_ANIMATED: u32 = @intCast(raven.R_SHADER_ANIMATED);
const R_PRIM_SHADER: u32 = @intCast(raven.R_PRIM_SHADER);
const R_INSTANCE_TEXTURED: u32 = @intCast(raven.R_INSTANCE_TEXTURED);
const R_INSTANCE_NO_POINTER: u32 = @intCast(raven.R_INSTANCE_NO_POINTER);

const rvn_effect_info_t = extern struct {
    name: [*c]const u8,
    code: [*c]const u32,
    size: usize,
    flags: raven.Ruint,
    color: u32,
    color2: u32,
    params: [4]f32,
};

// in the order of REffect
const g_effects = [_]rvn_effect_info_t{
    .{ .name = "aurora", .code = &effect_aurora.rvn_effect_aurora_spv, .size = @sizeOf(@TypeOf(effect_aurora.rvn_effect_aurora_spv)), .flags = R_SHADER_ANIMATED, .color = 0x30D158, .color2 = 0x5E5CE6, .params = .{ 1.0, 1.0, 1.5, 0.0 } },
    .{ .name = "shimmer", .code = &effect_shimmer.rvn_effect_shimmer_spv, .size = @sizeOf(@TypeOf(effect_shimmer.rvn_effect_shimmer_spv)), .flags = R_SHADER_ANIMATED, .color = 0x2C2C30, .color2 = 0x48484E, .params = .{ 1.0, 0.35, 20.0, 0.0 } },
    .{ .name = "neon", .code = &effect_neon.rvn_effect_neon_spv, .size = @sizeOf(@TypeOf(effect_neon.rvn_effect_neon_spv)), .flags = R_SHADER_ANIMATED, .color = 0x0A84FF, .color2 = 0xFF375F, .params = .{ 1.0, 2.0, 10.0, 0.0 } },
    .{ .name = "ripple", .code = &effect_ripple.rvn_effect_ripple_spv, .size = @sizeOf(@TypeOf(effect_ripple.rvn_effect_ripple_spv)), .flags = R_SHADER_ANIMATED | R_SHADER_BACKDROP, .color = 0x64D2FF, .color2 = 0xFFFFFF, .params = .{ 1.0, 6.0, 1.0, 0.5 } },
    .{ .name = "plasma", .code = &effect_plasma.rvn_effect_plasma_spv, .size = @sizeOf(@TypeOf(effect_plasma.rvn_effect_plasma_spv)), .flags = R_SHADER_ANIMATED, .color = 0x5E5CE6, .color2 = 0xFF9F0A, .params = .{ 1.0, 1.0, 1.0, 0.0 } },
    .{ .name = "grain", .code = &effect_grain.rvn_effect_grain_spv, .size = @sizeOf(@TypeOf(effect_grain.rvn_effect_grain_spv)), .flags = R_SHADER_ANIMATED, .color = 0x3A3A3F, .color2 = 0x1C1C1E, .params = .{ 0.6, 60.0, 0.0, 0.0 } },
    .{ .name = "spotlight", .code = &effect_spotlight.rvn_effect_spotlight_spv, .size = @sizeOf(@TypeOf(effect_spotlight.rvn_effect_spotlight_spv)), .flags = 0, .color = 0x2B2B60, .color2 = 0x141416, .params = .{ 0.3, 0.2, 0.7, 0.0 } },
    .{ .name = "mesh", .code = &effect_mesh.rvn_effect_mesh_spv, .size = @sizeOf(@TypeOf(effect_mesh.rvn_effect_mesh_spv)), .flags = R_SHADER_ANIMATED, .color = 0xFF6482, .color2 = 0x0A84FF, .params = .{ 1.0, 0.0, 0.0, 0.0 } },
};

// the built-in effects, made the first time they are asked for
var g_effect_ids: [RVN_EFFECT_COUNT]raven.Rid = std.mem.zeroes([RVN_EFFECT_COUNT]raven.Rid);

export fn rvn_shader_get(id: raven.Rid) [*c]renderer.rvn_shader_t {
    return @ptrCast(@alignCast(handle.rvn_pool_get(&ctx.g_rvn.shaders, id)));
}

fn rvn_shader_make(spirv: ?*const anyopaque, size: usize, flags: raven.Ruint, effect: c_int) raven.Rid {
    var magic: u32 = std.mem.zeroes(u32);
    // SPIR-V: whole 32-bit words, starting with its magic number (the bytes may have any alignment)
    if (spirv != null and size >= 4) {
        const magic_src: [*c]const u8 = @ptrCast(spirv);
        @memcpy(std.mem.asBytes(&magic), magic_src[0..4]);
    }
    if (spirv == null or size < 20 or size % 4 != 0 or magic != 0x07230203) {
        base.rvn_error(raven.R_ERROR_INVALID_VALUE, raven.R_SEVERITY_ERROR, "Rshader_create: this is not SPIR-V (compile the shader with glslangValidator -V or glslc)");
        return raven.R_INVALID_ID;
    }
    const shader: [*c]renderer.rvn_shader_t = @ptrCast(@alignCast(base.rvn_calloc(@sizeOf(renderer.rvn_shader_t))));
    shader.*.flags = flags;
    shader.*.effect = effect;
    shader.*.id = handle.rvn_pool_add(&ctx.g_rvn.shaders, shader);
    if (shader.*.id == raven.R_INVALID_ID) {
        base.rvn_free(shader);
        return raven.R_INVALID_ID;
    }
    const copy: [*c]u32 = @ptrCast(@alignCast(base.rvn_alloc(size)));
    const src: [*c]const u8 = @ptrCast(spirv);
    const dst: [*c]u8 = @ptrCast(copy);
    @memcpy(dst[0..size], src[0..size]); // memcpy(copy, spirv, size);
    renderer.rvn_renderer_create_shader(shader.*.id, copy, size);
    shader.*.created = raven.R_TRUE;
    return shader.*.id;
}

export fn Rshader_create(spirv: ?*const anyopaque, size: usize, flags: raven.Ruint) raven.Rid {
    if (ctx.rvn_api_check("Rshader_create") == 0) return raven.R_INVALID_ID;
    return rvn_shader_make(spirv, size, flags, -1);
}

export fn Rshader_create_from_file(path: [*c]const u8, flags: raven.Ruint) raven.Rid {
    var size: usize = std.mem.zeroes(usize);
    if (ctx.rvn_api_check("Rshader_create_from_file") == 0) return raven.R_INVALID_ID;
    if (path == null) return raven.R_INVALID_ID;
    const data = raven.Rfile_read(path, &size);
    if (data == null) {
        base.rvn_error(raven.R_ERROR_FILE_NOT_FOUND, raven.R_SEVERITY_ERROR, "Rshader_create_from_file: cannot read %s", path);
        return raven.R_INVALID_ID;
    }
    const id = rvn_shader_make(data, size, flags, -1);
    raven.Rmemory_free(data);
    return id;
}

// the .spv files named by Effect attributes: one shader each
const rvn_shader_file_t = extern struct {
    path: [*c]u8,
    flags: raven.Ruint,
    id: raven.Rid,
};
var g_shader_files: [*c]rvn_shader_file_t = std.mem.zeroes([*c]rvn_shader_file_t);
var g_shader_file_count: u32 = std.mem.zeroes(u32);
var g_shader_file_cap: u32 = std.mem.zeroes(u32);

export fn rvn_shader_from_file_cached(path: [*c]const u8, flags: raven.Ruint) raven.Rid {
    var i: u32 = std.mem.zeroes(u32);
    while (i < g_shader_file_count) : (i += 1) {
        if (g_shader_files[i].flags == flags and libc.strcmp(g_shader_files[i].path, path) == 0 and rvn_shader_get(g_shader_files[i].id) != null) return g_shader_files[i].id;
    }
    const id = Rshader_create_from_file(path, flags);
    if (id == raven.R_INVALID_ID) return raven.R_INVALID_ID;
    base.RVN_ARRAY_RESERVE(&g_shader_files, &g_shader_file_cap, g_shader_file_count + 1);
    g_shader_files[g_shader_file_count].path = base.rvn_strdup(path);
    g_shader_files[g_shader_file_count].flags = flags;
    g_shader_files[g_shader_file_count].id = id;
    g_shader_file_count += 1;
    return id;
}

export fn Rshader_destroy(id: raven.Rid) void {
    var i: c_int = std.mem.zeroes(c_int);
    if (ctx.rvn_api_check("Rshader_destroy") == 0) return;
    const shader = rvn_shader_get(id);
    if (shader == null) return;
    while (i < RVN_EFFECT_COUNT) : (i += 1) {
        if (g_effect_ids[@intCast(i)] == id) g_effect_ids[@intCast(i)] = raven.R_INVALID_ID;
    }
    // (the frames already queued were drawn with it before the command arrives: the render thread keeps the order)
    if (shader.*.created != 0) renderer.rvn_renderer_destroy_shader(id);
    handle.rvn_pool_remove(&ctx.g_rvn.shaders, id);
    base.rvn_free(shader);
}

export fn Rshader_is_valid(id: raven.Rid) c_int {
    return if (rvn_shader_get(id) != null) 1 else 0;
}

export fn Rshader_get_flags(id: raven.Rid) raven.Ruint {
    const shader = rvn_shader_get(id);
    return if (shader != null) shader.*.flags else 0;
}

export fn rvn_shaders_shutdown() void {
    var i: u32 = std.mem.zeroes(u32);
    while (i < ctx.g_rvn.shaders.used) : (i += 1) {
        const shader: [*c]renderer.rvn_shader_t = @ptrCast(@alignCast(handle.rvn_pool_at(&ctx.g_rvn.shaders, i)));
        if (shader == null) continue;
        if (shader.*.created != 0) renderer.rvn_renderer_destroy_shader(shader.*.id);
        handle.rvn_pool_remove(&ctx.g_rvn.shaders, shader.*.id);
        base.rvn_free(shader);
    }
    @memset(&g_effect_ids, 0);
    i = 0;
    while (i < g_shader_file_count) : (i += 1) base.rvn_free(g_shader_files[i].path);
    base.rvn_free(g_shader_files);
    g_shader_files = null;
    g_shader_file_count = 0;
    g_shader_file_cap = 0;
}

// ---------------------------------------------------------------------------
//  Built-in effects
// ---------------------------------------------------------------------------

export fn Reffect_get(effect: raven.REffect) raven.Rid {
    const index: c_int = @as(c_int, @bitCast(effect)) - raven.R_EFFECT_AURORA;
    if (ctx.rvn_api_check("Reffect_get") == 0) return raven.R_INVALID_ID;
    if (index < 0 or index >= RVN_EFFECT_COUNT) {
        base.rvn_error(raven.R_ERROR_INVALID_VALUE, raven.R_SEVERITY_ERROR, "Reffect_get: unknown effect %d", @as(c_int, @bitCast(effect)));
        return raven.R_INVALID_ID;
    }
    if (rvn_shader_get(g_effect_ids[@intCast(index)]) == null) {
        g_effect_ids[@intCast(index)] = rvn_shader_make(g_effects[@intCast(index)].code, g_effects[@intCast(index)].size, g_effects[@intCast(index)].flags, index);
    }
    return g_effect_ids[@intCast(index)];
}

export fn Reffect_find(name: [*c]const u8) raven.Rid {
    var i: c_int = std.mem.zeroes(c_int);
    if (name == null) return raven.R_INVALID_ID;
    while (i < RVN_EFFECT_COUNT) : (i += 1) {
        if (base.rvn_stricmp(g_effects[@intCast(i)].name, name) == 0) return Reffect_get(@as(raven.REffect, @bitCast(raven.R_EFFECT_AURORA + i)));
    }
    return raven.R_INVALID_ID;
}

export fn Reffect_get_name(effect: raven.REffect) [*c]const u8 {
    const index: c_int = @as(c_int, @bitCast(effect)) - raven.R_EFFECT_AURORA;
    return if (index >= 0 and index < RVN_EFFECT_COUNT) g_effects[@intCast(index)].name else "";
}

fn rvn_set_rgb(out: [*c]f32, rgb: u32) void {
    out[0] = @as(f32, @floatFromInt((rgb >> 16) & 0xFF)) / 255.0;
    out[1] = @as(f32, @floatFromInt((rgb >> 8) & 0xFF)) / 255.0;
    out[2] = @as(f32, @floatFromInt(rgb & 0xFF)) / 255.0;
    out[3] = 1.0;
}

export fn Rshader_look_init(look: [*c]raven.RShaderLook) void {
    var i: c_int = std.mem.zeroes(c_int);
    if (look == null) return;
    look.* = std.mem.zeroes(raven.RShaderLook);
    while (i < 4) : (i += 1) {
        look.*.color[@intCast(i)] = 1.0;
        look.*.color2[@intCast(i)] = 1.0;
    }
    look.*.texture = raven.R_INVALID_ID;
    look.*.animate = -1;
    look.*.pointer = raven.R_TRUE;
    look.*.hover = -1.0;
    look.*.press = -1.0;
}

export fn Reffect_get_defaults(effect: raven.REffect, look: [*c]raven.RShaderLook) void {
    const index: c_int = @as(c_int, @bitCast(effect)) - raven.R_EFFECT_AURORA;
    Rshader_look_init(look);
    if (look == null or index < 0 or index >= RVN_EFFECT_COUNT) return;
    rvn_set_rgb(&look.*.color, g_effects[@intCast(index)].color);
    rvn_set_rgb(&look.*.color2, g_effects[@intCast(index)].color2);
    look.*.params = g_effects[@intCast(index)].params; // memcpy(look->params, ..., sizeof(look->params))
}

export fn Rshader_look_defaults(id: raven.Rid, look: [*c]raven.RShaderLook) void {
    const shader = rvn_shader_get(id);
    if (shader != null and shader.*.effect >= 0) {
        Reffect_get_defaults(@as(raven.REffect, @bitCast(raven.R_EFFECT_AURORA + shader.*.effect)), look);
    } else {
        Rshader_look_init(look);
    }
}

// ---------------------------------------------------------------------------
//  Drawing
// ---------------------------------------------------------------------------

export fn rvn_paint_shader(painter: [*c]draw.RPainter, rect: base.rvn_rect_t, radii: [*c]const f32, id: raven.Rid, look: [*c]const raven.RShaderLook) void {
    const shader = rvn_shader_get(id);
    const box = draw.rvn_paint_snap(painter, rect);
    const opacity = base.rvn_clampf(painter.*.opacity, 0.0, 1.0);
    var animate: bool = undefined;

    if (shader == null or look == null or box.x1 <= box.x0 or box.y1 <= box.y0 or opacity <= 0.0) return;
    if (base.rvn_box_overlaps(box, painter.*.clip) == 0) return;
    const half = base.rvn_minf(box.x1 - box.x0, box.y1 - box.y0) * 0.5;
    // what is behind is captured first, a little around (an effect may look a few pixels away)
    if ((shader.*.flags & R_SHADER_BACKDROP) != 0) {
        const margin: f32 = 24.0 * painter.*.scale;
        draw.rvn_drawlist_add_backdrop(painter.*.list, base.rvn_box_intersect(painter.*.clip, base.rvn_box(box.x0 - margin, box.y0 - margin, box.x1 + margin, box.y1 + margin)));
    }
    const instance = draw.rvn_drawlist_add_shader(painter.*.list, id, look.*.texture);
    instance.* = std.mem.zeroes(raven.RDrawInstance); // memset(instance, 0, sizeof(*instance))
    instance.*.clip[0] = painter.*.clip.x0;
    instance.*.clip[1] = painter.*.clip.y0;
    instance.*.clip[2] = painter.*.clip.x1;
    instance.*.clip[3] = painter.*.clip.y1;
    instance.*.rect[0] = box.x0;
    instance.*.rect[1] = box.y0;
    instance.*.rect[2] = box.x1;
    instance.*.rect[3] = box.y1;
    var i: c_int = std.mem.zeroes(c_int);
    while (i < 4) : (i += 1) {
        const radius: f32 = if (radii != null) radii[@intCast(i)] else look.*.radius;
        instance.*.radii[@intCast(i)] = base.rvn_clampf(radius * painter.*.scale, 0.0, half);
        instance.*.uv[@intCast(i)] = look.*.params[@intCast(i)];
    }
    instance.*.color = base.rvn_rgba(look.*.color[0], look.*.color[1], look.*.color[2], look.*.color[3]);
    instance.*.border_color = base.rvn_rgba(look.*.color2[0], look.*.color2[1], look.*.color2[2], look.*.color2[3]);
    // (seconds that keep their precision in a float: the effects only care how they change)
    // reduced motion: the effects stand still (they still follow the pointer)
    instance.*.border_width = if (raven.Rget_animations_enabled() != 0) @as(f32, @floatCast(@rem(raven.Rget_time(), 3600.0))) else 0.0;
    instance.*.flags = R_PRIM_SHADER | (if (look.*.texture != raven.R_INVALID_ID) R_INSTANCE_TEXTURED else 0) | (@as(u32, @intFromFloat(opacity * 255.0 + 0.5)) << 8);
    animate = if (look.*.animate < 0) (shader.*.flags & R_SHADER_ANIMATED) != 0 else look.*.animate != 0;
    if (raven.Rget_animations_enabled() == 0) animate = false;
    if (look.*.pointer != 0) {
        // the pointer: how much it is over the rectangle and presses it (eased by a Border, else at once)
        var px: f32 = std.mem.zeroes(f32);
        var py: f32 = std.mem.zeroes(f32);
        var buttons: u32 = std.mem.zeroes(u32);
        var inside: bool = painter.*.window != null and draw.rvn_window_pointer(painter.*.window, &px, &py, &buttons) != 0;
        px *= painter.*.scale;
        py *= painter.*.scale;
        inside = inside and px >= box.x0 and py >= box.y0 and px < box.x1 and py < box.y1 and px >= painter.*.clip.x0 and py >= painter.*.clip.y0 and px < painter.*.clip.x1 and py < painter.*.clip.y1;
        const hover: f32 = if (look.*.hover >= 0.0) look.*.hover else if (inside) 1.0 else 0.0;
        const press: f32 = if (look.*.press >= 0.0) look.*.press else if (inside and (buttons & (@as(u32, 1) << @as(u5, @intCast(raven.R_MOUSE_LEFT)))) != 0) 1.0 else 0.0;
        instance.*.flags |= (@as(u32, @intFromFloat(base.rvn_clampf(hover, 0.0, 1.0) * 255.0 + 0.5)) << 16) | (@as(u32, @intFromFloat(base.rvn_clampf(press, 0.0, 1.0) * 255.0 + 0.5)) << 24);
        // while the pointer is over it, every frame shows where it is
        if (inside or hover > 0.0) animate = true;
    } else {
        instance.*.flags |= R_INSTANCE_NO_POINTER;
    }
    if (animate) draw.rvn_paint_keep_animating(painter);
}

export fn Rdraw_shader(painter: ?*raven.RPainter, shader: raven.Rid, x: f32, y: f32, width: f32, height: f32, look: [*c]const raven.RShaderLook) void {
    var defaults: raven.RShaderLook = undefined;
    var look_: [*c]const raven.RShaderLook = look;
    if (painter == null) return;
    if (look_ == null) {
        Rshader_look_defaults(shader, &defaults);
        look_ = &defaults;
    }
    rvn_paint_shader(@ptrCast(@alignCast(painter)), base.rvn_rect(x, y, width, height), null, shader, look_);
}
