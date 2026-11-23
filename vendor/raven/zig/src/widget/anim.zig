// Translated to Zig from vendor/raven/src/widget/anim.c (Raven, Apache-2.0). Modified by Seridian: C11 → Zig translation.
//
// Raven - widget/anim.c
// Springs, the transitions that play when a widget appears, and the
// settings of the animations.
//
// A spring is a damped oscillator pulled toward a target:
//
//     x'' = -w^2 (x - target) - 2 z w x'
//
// `w` sets how fast it answers (its period without friction is the
// "response", in seconds) and `z` how much it bounces: at 1 it lands without
// overshoot, below 1 it runs past the target and swings back. The motion is
// computed from the exact solution of the equation, so it does not depend on
// the frame rate and never explodes after a long frame.

const std = @import("std");
const raven = @import("raven");
const base = @import("../core/base_h.zig");
const ctx_h = @import("../core/context_h.zig");
const thread_h = @import("../core/thread_h.zig");
const draw_h = @import("../render/draw_h.zig");
const libc = @import("../sys/libc.zig");
const widget_h = @import("widget_h.zig");

const rvn_widget_t = widget_h.rvn_widget_t;

const rvn_motion_params_t = extern struct {
    /// Period of the spring without friction, in seconds.
    response: f32,
    /// Damping ratio: 1 = no bounce.
    damping: f32,
};

fn rvn_motion_params(motion: raven.RMotion) rvn_motion_params_t {
    var params: rvn_motion_params_t = undefined;
    switch (motion) {
        raven.R_MOTION_SMOOTH => {
            params.response = 0.30;
            params.damping = 1.0;
        },
        raven.R_MOTION_BOUNCY => {
            params.response = 0.38;
            params.damping = 0.52;
        },
        raven.R_MOTION_WOBBLY => {
            params.response = 0.50;
            params.damping = 0.32;
        },
        // R_MOTION_SNAPPY and default
        else => {
            params.response = 0.16;
            params.damping = 0.90;
        },
    }
    return params;
}

export fn rvn_spring_set(spring: [*c]raven.RSpring, value: f32) void {
    spring.*.value = value;
    spring.*.velocity = 0.0;
    spring.*.started = raven.R_TRUE;
}

export fn rvn_spring_kick(spring: [*c]raven.RSpring, velocity: f32) void {
    spring.*.velocity += velocity;
    spring.*.started = raven.R_TRUE;
}

export fn rvn_spring_moving(spring: [*c]const raven.RSpring, target: f32) c_int {
    return @intFromBool(spring.*.started != 0 and (@abs(spring.*.value - target) > 0.0015 or @abs(spring.*.velocity) > 0.02));
}

export fn rvn_paint_keep_animating(painter: [*c]draw_h.RPainter) void {
    if (painter.*.window) |window| {
        const win: [*c]widget_h.rvn_window_t = @ptrCast(@alignCast(window));
        thread_h.rvn_atomic_store(&win.*.animating, 1);
    }
}

/// Advances the spring by `dt` seconds.
fn rvn_spring_step(spring: [*c]raven.RSpring, target: f32, motion: raven.RMotion, dt: f32) void {
    const params = rvn_motion_params(motion);
    const omega: f32 = 6.2831853 / params.response;
    const zeta = params.damping;
    const x = spring.*.value - target;
    const v = spring.*.velocity;
    const decay = libc.expf(-zeta * omega * dt);

    if (zeta < 0.999) {
        const omega_d = omega * @sqrt(1.0 - zeta * zeta);
        const c = @cos(omega_d * dt);
        const s = @sin(omega_d * dt);
        const b = (v + zeta * omega * x) / omega_d;
        spring.*.value = target + decay * (x * c + b * s);
        spring.*.velocity = decay * ((b * omega_d - zeta * omega * x) * c - (x * omega_d + zeta * omega * b) * s);
    } else {
        // critically damped
        const b = v + omega * x;
        spring.*.value = target + decay * (x + b * dt);
        spring.*.velocity = decay * (b - omega * (x + b * dt));
    }
}

export fn rvn_paint_spring_from(painter: [*c]draw_h.RPainter, spring: [*c]raven.RSpring, target: f32, motion: raven.RMotion) f32 {
    spring.*.started = raven.R_TRUE;
    if (ctx_h.g_rvn.animations_disabled == 0 and rvn_spring_moving(spring, target) != 0) {
        rvn_spring_step(spring, target, motion, painter.*.dt);
        if (rvn_spring_moving(spring, target) != 0) {
            rvn_paint_keep_animating(painter);
            return spring.*.value;
        }
    }
    spring.*.value = target;
    spring.*.velocity = 0.0;
    return target;
}

export fn rvn_paint_spring(painter: [*c]draw_h.RPainter, spring: [*c]raven.RSpring, target: f32, motion: raven.RMotion) f32 {
    if (spring.*.started == 0) rvn_spring_set(spring, target);
    return rvn_paint_spring_from(painter, spring, target, motion);
}

export fn Rdraw_spring(painter: ?*raven.RPainter, spring: [*c]raven.RSpring, target: f32, motion_: raven.RMotion) f32 {
    if (painter == null or spring == null) return target;
    var motion = motion_;
    if (motion < raven.R_MOTION_SNAPPY or motion > raven.R_MOTION_WOBBLY) motion = raven.R_MOTION_SMOOTH;
    return rvn_paint_spring(@ptrCast(@alignCast(painter.?)), spring, target, motion);
}

export fn Rspring_kick(spring: [*c]raven.RSpring, velocity: f32) void {
    if (spring != null) rvn_spring_kick(spring, velocity);
}

export fn Rspring_set(spring: [*c]raven.RSpring, value: f32) void {
    if (spring != null) rvn_spring_set(spring, value);
}

// ---------------------------------------------------------------------------
//  Settings
// ---------------------------------------------------------------------------

export fn Rset_animations_enabled(enabled: c_int) void {
    if (ctx_h.rvn_api_check("Rset_animations_enabled") == 0) return;
    ctx_h.g_rvn.animations_disabled = @intFromBool(enabled == 0);
    ctx_h.rvn_repaint_all_windows();
}

export fn Rget_animations_enabled() c_int {
    return @intFromBool(ctx_h.g_rvn.animations_disabled == 0);
}

export fn Rset_animation_speed(speed: f32) void {
    if (ctx_h.rvn_api_check("Rset_animation_speed") == 0) return;
    if (!(speed > 0.0)) {
        base.rvn_error(raven.R_ERROR_INVALID_VALUE, raven.R_SEVERITY_ERROR, "Rset_animation_speed: the speed must be positive");
        return;
    }
    ctx_h.g_rvn.animation_speed = speed;
}

export fn Rget_animation_speed() f32 {
    return if (ctx_h.g_rvn.initialized != 0 and ctx_h.g_rvn.animation_speed > 0.0) ctx_h.g_rvn.animation_speed else 1.0;
}

export fn Rset_animation_time_step(seconds: f64) void {
    if (ctx_h.rvn_api_check("Rset_animation_time_step") == 0) return;
    ctx_h.g_rvn.animation_time_step = if (seconds > 0.0) seconds else 0.0;
}

/// Time by which the animations of a window advance, `elapsed` seconds after its previous frame.
export fn rvn_animation_dt(elapsed: f64) f32 {
    const speed: f32 = if (ctx_h.g_rvn.animation_speed > 0.0) ctx_h.g_rvn.animation_speed else 1.0;
    if (ctx_h.g_rvn.animation_time_step > 0.0) return @as(f32, @floatCast(ctx_h.g_rvn.animation_time_step)) * speed;
    // after a pause the animations resume gently instead of jumping
    return base.rvn_clampf(@floatCast(elapsed), 0.001, 1.0 / 30.0) * speed;
}

// ---------------------------------------------------------------------------
//  Transitions
// ---------------------------------------------------------------------------

fn rvn_widget_fx(widget: [*c]rvn_widget_t) [*c]widget_h.rvn_fx_t {
    if (widget.*.fx == null) widget.*.fx = @ptrCast(@alignCast(base.rvn_calloc(@sizeOf(widget_h.rvn_fx_t))));
    return widget.*.fx;
}

export fn rvn_widget_play_transition(widget: [*c]rvn_widget_t, transition: raven.RTransition, delay: f32) void {
    if (transition == raven.R_TRANSITION_NONE) {
        if (widget.*.fx != null) widget.*.fx.*.playing = raven.R_FALSE;
        return;
    }
    const fx = rvn_widget_fx(widget);
    fx.*.playing_kind = transition;
    fx.*.delay = base.rvn_maxf(delay, 0.0);
    fx.*.playing = raven.R_TRUE;
    fx.*.progress.value = 0.0;
    fx.*.progress.velocity = 0.0;
    fx.*.progress.started = raven.R_TRUE;
    widget_h.rvn_widget_invalidate_paint(widget);
}

export fn rvn_widget_appear(widget: [*c]rvn_widget_t) void {
    if (widget.*.fx != null and widget.*.fx.*.appear != raven.R_TRANSITION_NONE and widget.*.fx.*.appear != 0) {
        rvn_widget_play_transition(widget, widget.*.fx.*.appear, widget.*.fx.*.appear_delay);
    }
}

export fn rvn_transition_begin(widget: [*c]rvn_widget_t, painter: ?*raven.RPainter, state: [*c]widget_h.rvn_transition_state_t) c_int {
    const fx = widget.*.fx;
    const painter_: [*c]draw_h.RPainter = @ptrCast(@alignCast(painter));
    var t: f32 = undefined;
    var away: f32 = undefined;

    state.* = std.mem.zeroes(widget_h.rvn_transition_state_t);
    state.*.sx = 1.0;
    state.*.sy = 1.0;
    if (fx == null or fx.*.playing == 0) return raven.R_TRUE;
    if (ctx_h.g_rvn.animations_disabled != 0) {
        fx.*.playing = raven.R_FALSE;
        return raven.R_TRUE;
    }
    if (fx.*.delay > 0.0) {
        // waiting for its turn: not shown yet
        fx.*.delay -= painter_.*.dt;
        rvn_paint_keep_animating(painter_);
        return raven.R_FALSE;
    }

    const motion: raven.RMotion = switch (fx.*.playing_kind) {
        raven.R_TRANSITION_FADE => raven.R_MOTION_SMOOTH,
        raven.R_TRANSITION_POP => raven.R_MOTION_BOUNCY,
        raven.R_TRANSITION_ZOOM => raven.R_MOTION_SMOOTH,
        raven.R_TRANSITION_DROP => raven.R_MOTION_WOBBLY,
        raven.R_TRANSITION_SLIDE_LEFT, raven.R_TRANSITION_SLIDE_RIGHT => raven.R_MOTION_SNAPPY,
        else => raven.R_MOTION_BOUNCY,
    };
    t = rvn_paint_spring_from(painter_, &fx.*.progress, 1.0, motion);
    if (rvn_spring_moving(&fx.*.progress, 1.0) == 0) {
        fx.*.playing = raven.R_FALSE;
        return raven.R_TRUE;
    }
    away = 1.0 - t;
    state.*.active = raven.R_TRUE;
    // visible well before it lands: the motion is what should be seen
    state.*.opacity = base.rvn_clampf(t * 2.2, 0.0, 1.0);
    switch (fx.*.playing_kind) {
        raven.R_TRANSITION_POP => {
            state.*.sx = 0.55 + 0.45 * t;
            state.*.sy = state.*.sx;
        },
        raven.R_TRANSITION_ZOOM => {
            state.*.sx = 1.0 + 0.22 * away;
            state.*.sy = state.*.sx;
        },
        raven.R_TRANSITION_FLY_UP => {
            state.*.dy = 56.0 * away;
            state.*.sx = 1.0 - 0.08 * base.rvn_clampf(away, 0.0, 1.0);
            state.*.sy = state.*.sx;
        },
        raven.R_TRANSITION_FLY_DOWN => {
            state.*.dy = -56.0 * away;
            state.*.sx = 1.0 - 0.08 * base.rvn_clampf(away, 0.0, 1.0);
            state.*.sy = state.*.sx;
        },
        raven.R_TRANSITION_FLY_LEFT => {
            state.*.dx = 72.0 * away;
            state.*.sx = 1.0 - 0.08 * base.rvn_clampf(away, 0.0, 1.0);
            state.*.sy = state.*.sx;
        },
        raven.R_TRANSITION_FLY_RIGHT => {
            state.*.dx = -72.0 * away;
            state.*.sx = 1.0 - 0.08 * base.rvn_clampf(away, 0.0, 1.0);
            state.*.sy = state.*.sx;
        },
        raven.R_TRANSITION_SLIDE_LEFT => {
            state.*.dx = 28.0 * away;
        },
        raven.R_TRANSITION_SLIDE_RIGHT => {
            state.*.dx = -28.0 * away;
        },
        raven.R_TRANSITION_DROP => {
            // falls from above and lands with a squash
            state.*.dy = -140.0 * away;
            state.*.sy = 1.0 + 0.25 * base.rvn_clampf(away, -0.6, 0.6);
            state.*.sx = 1.0 - 0.12 * base.rvn_clampf(away, -0.6, 0.6);
            state.*.pivot_y = 0.5;
        },
        else => {},
    }
    return raven.R_TRUE;
}

// ---------------------------------------------------------------------------
//  Public
// ---------------------------------------------------------------------------

fn rvn_transition_valid(transition: raven.RTransition, function: [*c]const u8) c_int {
    if (transition >= raven.R_TRANSITION_NONE and transition <= raven.R_TRANSITION_SLIDE_RIGHT) return raven.R_TRUE;
    base.rvn_error(raven.R_ERROR_INVALID_ENUM, raven.R_SEVERITY_ERROR, "%s: invalid transition", function);
    return raven.R_FALSE;
}

export fn rvn_widget_set_appear(widget: [*c]rvn_widget_t, transition: [*c]const raven.RTransition, delay: [*c]const f32) void {
    const fx = rvn_widget_fx(widget);
    if (transition != null) fx.*.appear = transition.*;
    if (delay != null) fx.*.appear_delay = base.rvn_maxf(delay.*, 0.0);
    // a widget that is not shown yet plays it when it shows up
    if (fx.*.appear == raven.R_TRANSITION_NONE or fx.*.appear == 0) {
        fx.*.playing = raven.R_FALSE;
    } else {
        rvn_widget_play_transition(widget, fx.*.appear, fx.*.appear_delay);
    }
}

export fn Rwidget_set_transition(id: raven.Rid, transition: raven.RTransition, delay_seconds: f32) void {
    const widget = widget_h.rvn_widget_check(id, 0, "Rwidget_set_transition");
    if (widget == null) return;
    if (rvn_transition_valid(transition, "Rwidget_set_transition") == 0) return;
    rvn_widget_set_appear(widget, &transition, &delay_seconds);
}

export fn Rwidget_play_transition(id: raven.Rid, transition: raven.RTransition, delay_seconds: f32) void {
    const widget = widget_h.rvn_widget_check(id, 0, "Rwidget_play_transition");
    if (widget == null) return;
    if (rvn_transition_valid(transition, "Rwidget_play_transition") == 0) return;
    rvn_widget_play_transition(widget, transition, delay_seconds);
}

export fn rvn_parse_transition(text: [*c]const u8, transition: [*c]raven.RTransition) c_int {
    const names = [_]struct { name: [*c]const u8, value: raven.RTransition }{
        .{ .name = "None", .value = raven.R_TRANSITION_NONE },
        .{ .name = "Fade", .value = raven.R_TRANSITION_FADE },
        .{ .name = "Pop", .value = raven.R_TRANSITION_POP },
        .{ .name = "Zoom", .value = raven.R_TRANSITION_ZOOM },
        .{ .name = "FlyUp", .value = raven.R_TRANSITION_FLY_UP },
        .{ .name = "FlyDown", .value = raven.R_TRANSITION_FLY_DOWN },
        .{ .name = "FlyLeft", .value = raven.R_TRANSITION_FLY_LEFT },
        .{ .name = "FlyRight", .value = raven.R_TRANSITION_FLY_RIGHT },
        .{ .name = "Drop", .value = raven.R_TRANSITION_DROP },
        .{ .name = "SlideLeft", .value = raven.R_TRANSITION_SLIDE_LEFT },
        .{ .name = "SlideRight", .value = raven.R_TRANSITION_SLIDE_RIGHT },
    };
    var i: usize = 0;
    while (i < names.len) : (i += 1) {
        if (base.rvn_stricmp(text, names[i].name) == 0) {
            transition.* = names[i].value;
            return raven.R_TRUE;
        }
    }
    return raven.R_FALSE;
}
