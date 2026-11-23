#include "timeline_viewport.h"
#include <stdlib.h>
#include <stdio.h>
#include <math.h>

// Default values
#define DEFAULT_BPM 120.0
#define DEFAULT_TIME_SIG_NUM 4
#define DEFAULT_TIME_SIG_DENOM 4
#define DEFAULT_PIXELS_PER_BEAT 50.0
#define MIN_PIXELS_PER_BEAT 10.0
#define MAX_PIXELS_PER_BEAT 400.0

struct TimelineViewport {
    ViewportState state;
    int viewport_width;
    int track_header_width;
};

// Internal: recalculate derived values
static void recalculate_state(TimelineViewport *vp) {
    ViewportState *s = &vp->state;

    // Time calculations
    s->seconds_per_beat = 60.0 / s->bpm;
    s->seconds_per_bar = s->seconds_per_beat * s->time_sig_numerator;
    s->pixels_per_second = s->pixels_per_beat / s->seconds_per_beat;
    s->pixels_per_bar = s->pixels_per_beat * s->time_sig_numerator;

    // Visible range
    int content_width = vp->viewport_width - vp->track_header_width;
    if (content_width < 1) content_width = 1;

    s->visible_duration = content_width / s->pixels_per_second;
    s->visible_start_bar = (int)(s->scroll_x / s->seconds_per_bar);
    s->visible_end_bar = (int)((s->scroll_x + s->visible_duration) / s->seconds_per_bar) + 1;

    // Clamp to reasonable values
    if (s->visible_start_bar < 0) s->visible_start_bar = 0;
    if (s->visible_end_bar < s->visible_start_bar) s->visible_end_bar = s->visible_start_bar + 1;
}

TimelineViewport* timeline_viewport_new(void) {
    TimelineViewport *vp = malloc(sizeof(TimelineViewport));
    if (!vp) return NULL;

    // Initialize defaults
    vp->state.scroll_x = 0.0;
    vp->state.pixels_per_beat = DEFAULT_PIXELS_PER_BEAT;
    vp->state.bpm = DEFAULT_BPM;
    vp->state.time_sig_numerator = DEFAULT_TIME_SIG_NUM;
    vp->state.time_sig_denominator = DEFAULT_TIME_SIG_DENOM;

    vp->viewport_width = 800;
    vp->track_header_width = 100;

    recalculate_state(vp);

    printf("🎬 Timeline viewport created (%.0f BPM, %.0f px/beat)\n",
           vp->state.bpm, vp->state.pixels_per_beat);

    return vp;
}

void timeline_viewport_destroy(TimelineViewport *vp) {
    if (vp) {
        free(vp);
        printf("🎬 Timeline viewport destroyed\n");
    }
}

const ViewportState* timeline_viewport_get_state(TimelineViewport *vp) {
    return vp ? &vp->state : NULL;
}

void timeline_viewport_set_tempo(TimelineViewport *vp, double bpm, int numerator, int denominator) {
    if (!vp) return;
    if (bpm < 20.0) bpm = 20.0;
    if (bpm > 999.0) bpm = 999.0;
    if (numerator < 1) numerator = 1;
    if (numerator > 16) numerator = 16;
    if (denominator < 1) denominator = 1;
    if (denominator > 16) denominator = 16;

    vp->state.bpm = bpm;
    vp->state.time_sig_numerator = numerator;
    vp->state.time_sig_denominator = denominator;
    recalculate_state(vp);
}

void timeline_viewport_set_viewport_width(TimelineViewport *vp, int width, int track_header_width) {
    if (!vp) return;
    vp->viewport_width = width > 0 ? width : 1;
    vp->track_header_width = track_header_width > 0 ? track_header_width : 0;
    recalculate_state(vp);
}

void timeline_viewport_set_scroll(TimelineViewport *vp, double scroll_x) {
    if (!vp) return;
    vp->state.scroll_x = scroll_x < 0.0 ? 0.0 : scroll_x;
    recalculate_state(vp);
}

void timeline_viewport_scroll_by(TimelineViewport *vp, double delta_seconds) {
    if (!vp) return;
    double new_scroll = vp->state.scroll_x + delta_seconds;
    timeline_viewport_set_scroll(vp, new_scroll);
}

void timeline_viewport_scroll_to_bar(TimelineViewport *vp, int bar) {
    if (!vp) return;
    double seconds = bar * vp->state.seconds_per_bar;
    timeline_viewport_set_scroll(vp, seconds);
}

void timeline_viewport_scroll_to_playhead(TimelineViewport *vp, double playhead_seconds) {
    if (!vp) return;

    // Keep playhead at ~20% from left edge
    double target_scroll = playhead_seconds - (vp->state.visible_duration * 0.2);
    timeline_viewport_set_scroll(vp, target_scroll);
}

void timeline_viewport_set_zoom(TimelineViewport *vp, double pixels_per_beat) {
    if (!vp) return;

    // Clamp zoom level
    if (pixels_per_beat < MIN_PIXELS_PER_BEAT) pixels_per_beat = MIN_PIXELS_PER_BEAT;
    if (pixels_per_beat > MAX_PIXELS_PER_BEAT) pixels_per_beat = MAX_PIXELS_PER_BEAT;

    vp->state.pixels_per_beat = pixels_per_beat;
    recalculate_state(vp);
}

void timeline_viewport_zoom_by(TimelineViewport *vp, double factor) {
    if (!vp) return;
    timeline_viewport_set_zoom(vp, vp->state.pixels_per_beat * factor);
}

void timeline_viewport_zoom_at_point(TimelineViewport *vp, double screen_x, double factor, int track_header_width) {
    if (!vp) return;

    // Get time at cursor before zoom
    double time_at_cursor = timeline_viewport_x_to_seconds(vp, screen_x, track_header_width);

    // Apply zoom
    timeline_viewport_zoom_by(vp, factor);

    // Adjust scroll so time at cursor stays at same screen position
    double content_x = screen_x - track_header_width;
    double new_scroll = time_at_cursor - (content_x / vp->state.pixels_per_second);
    timeline_viewport_set_scroll(vp, new_scroll);
}

void timeline_viewport_zoom_to_fit(TimelineViewport *vp, double start_seconds, double end_seconds,
                                    int width, int track_header_width) {
    if (!vp) return;
    if (end_seconds <= start_seconds) return;

    int content_width = width - track_header_width;
    if (content_width < 1) return;

    double duration = end_seconds - start_seconds;
    double required_pps = content_width / duration;
    double required_ppb = required_pps * vp->state.seconds_per_beat;

    timeline_viewport_set_zoom(vp, required_ppb);
    timeline_viewport_set_scroll(vp, start_seconds);
}

double timeline_viewport_x_to_seconds(TimelineViewport *vp, double screen_x, int track_header_width) {
    if (!vp) return 0.0;

    double content_x = screen_x - track_header_width;
    return vp->state.scroll_x + (content_x / vp->state.pixels_per_second);
}

double timeline_viewport_seconds_to_x(TimelineViewport *vp, double seconds, int track_header_width) {
    if (!vp) return 0.0;

    double content_x = (seconds - vp->state.scroll_x) * vp->state.pixels_per_second;
    return track_header_width + content_x;
}

int timeline_viewport_x_to_bar(TimelineViewport *vp, double screen_x, int track_header_width) {
    if (!vp) return 0;

    double seconds = timeline_viewport_x_to_seconds(vp, screen_x, track_header_width);
    return (int)(seconds / vp->state.seconds_per_bar);
}

int timeline_viewport_x_to_beat(TimelineViewport *vp, double screen_x, int track_header_width) {
    if (!vp) return 0;

    double seconds = timeline_viewport_x_to_seconds(vp, screen_x, track_header_width);
    return (int)(seconds / vp->state.seconds_per_beat);
}

double timeline_viewport_snap_to_grid(TimelineViewport *vp, double seconds, int grid_subdivision) {
    if (!vp || grid_subdivision < 1) return seconds;

    // grid_subdivision: 1=bar, 4=beat (in 4/4), 16=16th note, etc.
    double grid_size = vp->state.seconds_per_bar / grid_subdivision;
    return round(seconds / grid_size) * grid_size;
}

bool timeline_viewport_is_time_visible(TimelineViewport *vp, double seconds) {
    if (!vp) return false;

    double end_time = vp->state.scroll_x + vp->state.visible_duration;
    return seconds >= vp->state.scroll_x && seconds <= end_time;
}

bool timeline_viewport_is_range_visible(TimelineViewport *vp, double start_seconds, double end_seconds) {
    if (!vp) return false;

    double view_start = vp->state.scroll_x;
    double view_end = view_start + vp->state.visible_duration;

    // Range is visible if it overlaps with viewport
    return start_seconds < view_end && end_seconds > view_start;
}

void timeline_viewport_foreach_grid_line(TimelineViewport *vp, int track_header_width, int viewport_width,
                                          GridLineCallback callback, void *user_data) {
    if (!vp || !callback) return;

    const ViewportState *s = &vp->state;

    // Determine grid density based on zoom level
    // At low zoom, show only bar lines; at high zoom, show beat subdivisions
    int beats_per_visible_line = 1;
    double min_pixel_spacing = 20.0; // Minimum pixels between grid lines

    if (s->pixels_per_beat < min_pixel_spacing) {
        // Too zoomed out - skip some beats
        beats_per_visible_line = (int)ceil(min_pixel_spacing / s->pixels_per_beat);
    }

    // Calculate range in beats
    int start_beat = (int)(s->scroll_x / s->seconds_per_beat);
    int end_beat = (int)((s->scroll_x + s->visible_duration) / s->seconds_per_beat) + 1;

    // Align to grid subdivision
    start_beat = (start_beat / beats_per_visible_line) * beats_per_visible_line;

    for (int beat = start_beat; beat <= end_beat; beat += beats_per_visible_line) {
        double beat_time = beat * s->seconds_per_beat;
        double x = timeline_viewport_seconds_to_x(vp, beat_time, track_header_width);

        // Skip if off-screen
        if (x < track_header_width - 1 || x > viewport_width + 1) continue;

        int bar = beat / s->time_sig_numerator;
        int beat_in_bar = beat % s->time_sig_numerator;
        bool is_bar_line = (beat_in_bar == 0);

        callback(bar, beat_in_bar, x, is_bar_line, user_data);
    }
}
