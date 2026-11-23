#ifndef TIMELINE_VIEWPORT_H
#define TIMELINE_VIEWPORT_H

#include <stdbool.h>
#include <stdint.h>

typedef struct TimelineViewport TimelineViewport;

// Viewport state (read-only access)
typedef struct {
    double scroll_x;           // Horizontal scroll position in seconds
    double pixels_per_beat;    // Zoom level (higher = more zoomed in)
    double bpm;                // Current tempo
    int time_sig_numerator;    // Beats per bar
    int time_sig_denominator;  // Beat unit

    // Calculated values (updated on state change)
    double seconds_per_beat;
    double seconds_per_bar;
    double pixels_per_second;
    double pixels_per_bar;
    int visible_start_bar;     // First visible bar (0-indexed)
    int visible_end_bar;       // Last visible bar
    double visible_duration;   // Duration visible in viewport (seconds)
} ViewportState;

// Lifecycle
TimelineViewport* timeline_viewport_new(void);
void timeline_viewport_destroy(TimelineViewport *vp);

// State access
const ViewportState* timeline_viewport_get_state(TimelineViewport *vp);

// Configuration
void timeline_viewport_set_tempo(TimelineViewport *vp, double bpm, int numerator, int denominator);
void timeline_viewport_set_viewport_width(TimelineViewport *vp, int width, int track_header_width);

// Navigation
void timeline_viewport_set_scroll(TimelineViewport *vp, double scroll_x);
void timeline_viewport_scroll_by(TimelineViewport *vp, double delta_seconds);
void timeline_viewport_scroll_to_bar(TimelineViewport *vp, int bar);
void timeline_viewport_scroll_to_playhead(TimelineViewport *vp, double playhead_seconds);

// Zoom
void timeline_viewport_set_zoom(TimelineViewport *vp, double pixels_per_beat);
void timeline_viewport_zoom_by(TimelineViewport *vp, double factor);
void timeline_viewport_zoom_at_point(TimelineViewport *vp, double screen_x, double factor, int track_header_width);

// Zoom presets
void timeline_viewport_zoom_to_fit(TimelineViewport *vp, double start_seconds, double end_seconds, int width, int track_header_width);

// Coordinate conversion
double timeline_viewport_x_to_seconds(TimelineViewport *vp, double screen_x, int track_header_width);
double timeline_viewport_seconds_to_x(TimelineViewport *vp, double seconds, int track_header_width);
int timeline_viewport_x_to_bar(TimelineViewport *vp, double screen_x, int track_header_width);
int timeline_viewport_x_to_beat(TimelineViewport *vp, double screen_x, int track_header_width);

// Snapping
double timeline_viewport_snap_to_grid(TimelineViewport *vp, double seconds, int grid_subdivision);

// Visibility testing
bool timeline_viewport_is_time_visible(TimelineViewport *vp, double seconds);
bool timeline_viewport_is_range_visible(TimelineViewport *vp, double start_seconds, double end_seconds);

// Grid drawing helpers
typedef void (*GridLineCallback)(int bar, int beat, double x, bool is_bar_line, void *user_data);
void timeline_viewport_foreach_grid_line(TimelineViewport *vp, int track_header_width, int viewport_width,
                                          GridLineCallback callback, void *user_data);

#endif // TIMELINE_VIEWPORT_H
