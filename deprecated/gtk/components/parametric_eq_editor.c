/**
 * Parametric EQ Editor - FabFilter Pro-Q Style Visual EQ
 *
 * A visual parametric EQ with:
 * - Frequency response curve
 * - Draggable band nodes
 * - Real-time visual feedback
 */

#include "parametric_eq_editor.h"
#include "daw_widgets.h"
#include "effects_chain_gtk.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>

// Portable M_PI definition
#ifndef M_PI
#define M_PI 3.14159265358979323846
#endif

// Display constants
#define EQ_WIDTH 600
#define EQ_HEIGHT 300
#define EQ_MARGIN_LEFT 50
#define EQ_MARGIN_RIGHT 20
#define EQ_MARGIN_TOP 20
#define EQ_MARGIN_BOTTOM 40

// Frequency range (log scale)
#define FREQ_MIN 20.0
#define FREQ_MAX 20000.0

// Gain range
#define GAIN_MIN -18.0
#define GAIN_MAX 18.0

// Band node radius
#define NODE_RADIUS 10
#define NODE_RADIUS_HOVER 12

// Band colors (Tokyo Night palette)
static const double BAND_COLORS[][3] = {
    {0.96, 0.47, 0.56},  // Red - Low Shelf
    {0.89, 0.69, 0.41},  // Orange - Mid 1
    {0.62, 0.81, 0.42},  // Green - Mid 2
    {0.49, 0.81, 1.00},  // Cyan - High Shelf
};

// EQ Editor structure
struct ParametricEQEditor {
    GtkWidget *container;
    GtkWidget *drawing_area;
    GtkWidget *controls_box;

    void *audio_engine;
    int track;
    int effect_slot;

    // Band parameters (cached for drawing)
    // 4 bands x 3 params: freq, gain, Q
    float band_freq[4];
    float band_gain[4];
    float band_q[4];
    float output_gain;

    // Interaction state
    int hovered_band;    // -1 = none
    int dragged_band;    // -1 = none
    double drag_start_x;
    double drag_start_y;
    float drag_start_freq;
    float drag_start_gain;

    // Parameter widgets for fine control
    GtkWidget *freq_sliders[4];
    GtkWidget *gain_sliders[4];
    GtkWidget *q_sliders[4];
    GtkWidget *output_slider;
};

// Forward declarations
static void update_params_from_engine(ParametricEQEditor *eq);
static void on_draw(GtkDrawingArea *area, cairo_t *cr, int width, int height, gpointer user_data);
static void on_motion(GtkEventControllerMotion *controller, double x, double y, gpointer user_data);
static void on_press(GtkGestureClick *gesture, int n_press, double x, double y, gpointer user_data);
static void on_release(GtkGestureClick *gesture, int n_press, double x, double y, gpointer user_data);
static void on_drag(GtkGestureDrag *gesture, double offset_x, double offset_y, gpointer user_data);
static gboolean on_scroll(GtkEventControllerScroll *controller, double dx, double dy, gpointer user_data);
static void on_param_changed(float value, int param_index, void *user_data);

// Utility: Convert frequency to X position (log scale)
static double freq_to_x(double freq, int width) {
    double plot_width = width - EQ_MARGIN_LEFT - EQ_MARGIN_RIGHT;
    double log_min = log10(FREQ_MIN);
    double log_max = log10(FREQ_MAX);
    double log_freq = log10(fmax(FREQ_MIN, fmin(FREQ_MAX, freq)));
    return EQ_MARGIN_LEFT + plot_width * (log_freq - log_min) / (log_max - log_min);
}

// Utility: Convert X position to frequency
static double x_to_freq(double x, int width) {
    double plot_width = width - EQ_MARGIN_LEFT - EQ_MARGIN_RIGHT;
    double log_min = log10(FREQ_MIN);
    double log_max = log10(FREQ_MAX);
    double ratio = (x - EQ_MARGIN_LEFT) / plot_width;
    ratio = fmax(0.0, fmin(1.0, ratio));
    return pow(10.0, log_min + ratio * (log_max - log_min));
}

// Utility: Convert gain to Y position
static double gain_to_y(double gain, int height) {
    double plot_height = height - EQ_MARGIN_TOP - EQ_MARGIN_BOTTOM;
    double ratio = (gain - GAIN_MIN) / (GAIN_MAX - GAIN_MIN);
    return EQ_MARGIN_TOP + plot_height * (1.0 - ratio);
}

// Utility: Convert Y position to gain
static double y_to_gain(double y, int height) {
    double plot_height = height - EQ_MARGIN_TOP - EQ_MARGIN_BOTTOM;
    double ratio = 1.0 - (y - EQ_MARGIN_TOP) / plot_height;
    ratio = fmax(0.0, fmin(1.0, ratio));
    return GAIN_MIN + ratio * (GAIN_MAX - GAIN_MIN);
}

// Calculate biquad magnitude response at a frequency
// freq: frequency at which to evaluate the response
// center_freq: filter's center/cutoff frequency
// gain_db: filter gain in dB
// q: filter Q factor
// filter_type: 0=low shelf, 1/2=peak, 3=high shelf
// sample_rate: sample rate in Hz
static double calc_biquad_magnitude(double freq, double center_freq, double gain_db, double q,
                                    int filter_type, double sample_rate) {
    if (fabs(gain_db) < 0.1) return 1.0;  // Passthrough

    // Calculate coefficients at center_freq
    double omega = 2.0 * M_PI * center_freq / sample_rate;
    double cos_omega = cos(omega);
    double sin_omega = sin(omega);
    double alpha = sin_omega / (2.0 * q);
    double A = pow(10.0, gain_db / 40.0);
    double sq_A = sqrt(A);

    double b0, b1, b2, a0, a1, a2;

    switch (filter_type) {
        case 0:  // Low Shelf
            b0 = A * ((A + 1) - (A - 1) * cos_omega + 2 * sq_A * alpha);
            b1 = 2 * A * ((A - 1) - (A + 1) * cos_omega);
            b2 = A * ((A + 1) - (A - 1) * cos_omega - 2 * sq_A * alpha);
            a0 = (A + 1) + (A - 1) * cos_omega + 2 * sq_A * alpha;
            a1 = -2 * ((A - 1) + (A + 1) * cos_omega);
            a2 = (A + 1) + (A - 1) * cos_omega - 2 * sq_A * alpha;
            break;
        case 3:  // High Shelf
            b0 = A * ((A + 1) + (A - 1) * cos_omega + 2 * sq_A * alpha);
            b1 = -2 * A * ((A - 1) + (A + 1) * cos_omega);
            b2 = A * ((A + 1) + (A - 1) * cos_omega - 2 * sq_A * alpha);
            a0 = (A + 1) - (A - 1) * cos_omega + 2 * sq_A * alpha;
            a1 = 2 * ((A - 1) - (A + 1) * cos_omega);
            a2 = (A + 1) - (A - 1) * cos_omega - 2 * sq_A * alpha;
            break;
        default:  // Peak (bands 1, 2)
            b0 = 1 + alpha * A;
            b1 = -2 * cos_omega;
            b2 = 1 - alpha * A;
            a0 = 1 + alpha / A;
            a1 = -2 * cos_omega;
            a2 = 1 - alpha / A;
            break;
    }

    // Normalize
    b0 /= a0; b1 /= a0; b2 /= a0;
    a1 /= a0; a2 /= a0;

    // Calculate magnitude at evaluation frequency (freq, not center_freq)
    double w = 2.0 * M_PI * freq / sample_rate;
    double cos_w = cos(w);
    double cos_2w = cos(2 * w);
    double sin_w = sin(w);
    double sin_2w = sin(2 * w);

    double real_num = b0 + b1 * cos_w + b2 * cos_2w;
    double imag_num = -b1 * sin_w - b2 * sin_2w;
    double real_den = 1 + a1 * cos_w + a2 * cos_2w;
    double imag_den = -a1 * sin_w - a2 * sin_2w;

    double num_mag = sqrt(real_num * real_num + imag_num * imag_num);
    double den_mag = sqrt(real_den * real_den + imag_den * imag_den);

    return (den_mag > 0.0001) ? num_mag / den_mag : 1.0;
}

// Calculate total EQ magnitude at frequency
static double calc_total_magnitude(ParametricEQEditor *eq, double freq) {
    double sample_rate = 48000.0;
    double total = 1.0;

    // Band 0: Low Shelf
    total *= calc_biquad_magnitude(freq, eq->band_freq[0], eq->band_gain[0], eq->band_q[0], 0, sample_rate);
    // Band 1: Peak
    total *= calc_biquad_magnitude(freq, eq->band_freq[1], eq->band_gain[1], eq->band_q[1], 1, sample_rate);
    // Band 2: Peak
    total *= calc_biquad_magnitude(freq, eq->band_freq[2], eq->band_gain[2], eq->band_q[2], 2, sample_rate);
    // Band 3: High Shelf
    total *= calc_biquad_magnitude(freq, eq->band_freq[3], eq->band_gain[3], eq->band_q[3], 3, sample_rate);

    // Apply output gain
    total *= pow(10.0, eq->output_gain / 20.0);

    return total;
}

// Draw the EQ visualization
static void on_draw(GtkDrawingArea *area, cairo_t *cr, int width, int height, gpointer user_data) {
    (void)area;
    ParametricEQEditor *eq = (ParametricEQEditor *)user_data;
    if (!eq) return;

    double plot_left = EQ_MARGIN_LEFT;
    double plot_right = width - EQ_MARGIN_RIGHT;
    double plot_top = EQ_MARGIN_TOP;
    double plot_bottom = height - EQ_MARGIN_BOTTOM;
    double plot_width = plot_right - plot_left;
    double plot_height = plot_bottom - plot_top;

    // Background
    cairo_set_source_rgb(cr, 0.09, 0.09, 0.12);
    cairo_paint(cr);

    // Grid background
    cairo_set_source_rgb(cr, 0.12, 0.13, 0.17);
    cairo_rectangle(cr, plot_left, plot_top, plot_width, plot_height);
    cairo_fill(cr);

    // Draw frequency grid lines (log scale)
    cairo_set_line_width(cr, 1.0);
    double freqs[] = {20, 50, 100, 200, 500, 1000, 2000, 5000, 10000, 20000};
    int num_freqs = sizeof(freqs) / sizeof(freqs[0]);

    for (int i = 0; i < num_freqs; i++) {
        double x = freq_to_x(freqs[i], width);

        // Grid line
        if (freqs[i] == 100 || freqs[i] == 1000 || freqs[i] == 10000) {
            cairo_set_source_rgba(cr, 0.4, 0.4, 0.5, 0.5);
        } else {
            cairo_set_source_rgba(cr, 0.3, 0.3, 0.4, 0.3);
        }
        cairo_move_to(cr, x, plot_top);
        cairo_line_to(cr, x, plot_bottom);
        cairo_stroke(cr);

        // Label
        cairo_set_source_rgba(cr, 0.6, 0.6, 0.7, 0.8);
        cairo_select_font_face(cr, "sans-serif", CAIRO_FONT_SLANT_NORMAL, CAIRO_FONT_WEIGHT_NORMAL);
        cairo_set_font_size(cr, 10);

        char label[16];
        if (freqs[i] >= 1000) {
            snprintf(label, sizeof(label), "%.0fk", freqs[i] / 1000);
        } else {
            snprintf(label, sizeof(label), "%.0f", freqs[i]);
        }

        cairo_text_extents_t extents;
        cairo_text_extents(cr, label, &extents);
        cairo_move_to(cr, x - extents.width / 2, plot_bottom + 15);
        cairo_show_text(cr, label);
    }

    // Draw gain grid lines
    double gains[] = {-18, -12, -6, 0, 6, 12, 18};
    int num_gains = sizeof(gains) / sizeof(gains[0]);

    for (int i = 0; i < num_gains; i++) {
        double y = gain_to_y(gains[i], height);

        if (gains[i] == 0) {
            cairo_set_source_rgba(cr, 0.5, 0.5, 0.6, 0.7);
            cairo_set_line_width(cr, 1.5);
        } else {
            cairo_set_source_rgba(cr, 0.3, 0.3, 0.4, 0.3);
            cairo_set_line_width(cr, 1.0);
        }
        cairo_move_to(cr, plot_left, y);
        cairo_line_to(cr, plot_right, y);
        cairo_stroke(cr);

        // Label
        cairo_set_source_rgba(cr, 0.6, 0.6, 0.7, 0.8);
        cairo_set_font_size(cr, 10);

        char label[16];
        snprintf(label, sizeof(label), "%+.0f dB", gains[i]);

        cairo_text_extents_t extents;
        cairo_text_extents(cr, label, &extents);
        cairo_move_to(cr, plot_left - extents.width - 5, y + extents.height / 2 - 2);
        cairo_show_text(cr, label);
    }

    // Draw individual band curves (semi-transparent)
    for (int band = 0; band < 4; band++) {
        if (fabs(eq->band_gain[band]) < 0.1) continue;  // Skip flat bands

        cairo_set_source_rgba(cr, BAND_COLORS[band][0], BAND_COLORS[band][1], BAND_COLORS[band][2], 0.3);
        cairo_set_line_width(cr, 1.5);

        int filter_type = (band == 0) ? 0 : (band == 3) ? 3 : 1;

        gboolean first = TRUE;
        for (int px = (int)plot_left; px <= (int)plot_right; px++) {
            double freq = x_to_freq(px, width);
            double mag = calc_biquad_magnitude(freq, eq->band_freq[band], eq->band_gain[band],
                                               eq->band_q[band], filter_type, 48000.0);
            double db = 20.0 * log10(fmax(0.001, mag));
            double y = gain_to_y(db, height);

            if (first) {
                cairo_move_to(cr, px, y);
                first = FALSE;
            } else {
                cairo_line_to(cr, px, y);
            }
        }
        cairo_stroke(cr);
    }

    // Draw combined response curve
    cairo_set_source_rgb(cr, 0.49, 0.81, 1.00);  // Cyan
    cairo_set_line_width(cr, 2.5);

    // Create fill path
    cairo_move_to(cr, plot_left, gain_to_y(0, height));

    for (int px = (int)plot_left; px <= (int)plot_right; px++) {
        double freq = x_to_freq(px, width);
        double mag = calc_total_magnitude(eq, freq);
        double db = 20.0 * log10(fmax(0.001, mag));
        double y = gain_to_y(db, height);
        cairo_line_to(cr, px, y);
    }

    // Fill under curve
    cairo_line_to(cr, plot_right, gain_to_y(0, height));
    cairo_close_path(cr);

    cairo_set_source_rgba(cr, 0.49, 0.81, 1.00, 0.15);
    cairo_fill_preserve(cr);

    // Stroke the curve
    cairo_set_source_rgb(cr, 0.49, 0.81, 1.00);
    cairo_stroke(cr);

    // Draw band nodes
    for (int band = 0; band < 4; band++) {
        double x = freq_to_x(eq->band_freq[band], width);
        double y = gain_to_y(eq->band_gain[band], height);

        // Node glow for hovered/dragged
        if (eq->hovered_band == band || eq->dragged_band == band) {
            cairo_set_source_rgba(cr, BAND_COLORS[band][0], BAND_COLORS[band][1], BAND_COLORS[band][2], 0.4);
            cairo_arc(cr, x, y, NODE_RADIUS_HOVER + 4, 0, 2 * M_PI);
            cairo_fill(cr);
        }

        // Node outer ring
        cairo_set_source_rgb(cr, BAND_COLORS[band][0], BAND_COLORS[band][1], BAND_COLORS[band][2]);
        double radius = (eq->hovered_band == band || eq->dragged_band == band) ? NODE_RADIUS_HOVER : NODE_RADIUS;
        cairo_arc(cr, x, y, radius, 0, 2 * M_PI);
        cairo_fill(cr);

        // Node inner circle
        cairo_set_source_rgb(cr, 0.12, 0.13, 0.17);
        cairo_arc(cr, x, y, radius - 3, 0, 2 * M_PI);
        cairo_fill(cr);

        // Band number
        cairo_set_source_rgb(cr, BAND_COLORS[band][0], BAND_COLORS[band][1], BAND_COLORS[band][2]);
        cairo_set_font_size(cr, 10);
        char num[4];
        snprintf(num, sizeof(num), "%d", band + 1);
        cairo_text_extents_t extents;
        cairo_text_extents(cr, num, &extents);
        cairo_move_to(cr, x - extents.width / 2, y + extents.height / 2 - 1);
        cairo_show_text(cr, num);
    }

    // Draw border
    cairo_set_source_rgba(cr, 0.3, 0.3, 0.4, 0.5);
    cairo_set_line_width(cr, 1.0);
    cairo_rectangle(cr, plot_left, plot_top, plot_width, plot_height);
    cairo_stroke(cr);
}

// Find band at position
static int find_band_at(ParametricEQEditor *eq, double x, double y, int width, int height) {
    for (int band = 3; band >= 0; band--) {  // Check from top (reverse order for z-order)
        double bx = freq_to_x(eq->band_freq[band], width);
        double by = gain_to_y(eq->band_gain[band], height);
        double dist = sqrt((x - bx) * (x - bx) + (y - by) * (y - by));
        if (dist <= NODE_RADIUS_HOVER + 2) {
            return band;
        }
    }
    return -1;
}

// Motion handler for hover effects
static void on_motion(GtkEventControllerMotion *controller, double x, double y, gpointer user_data) {
    (void)controller;
    ParametricEQEditor *eq = (ParametricEQEditor *)user_data;
    if (!eq || !eq->drawing_area) return;

    int width = gtk_widget_get_width(eq->drawing_area);
    int height = gtk_widget_get_height(eq->drawing_area);

    int old_hover = eq->hovered_band;
    eq->hovered_band = find_band_at(eq, x, y, width, height);

    if (old_hover != eq->hovered_band) {
        gtk_widget_queue_draw(eq->drawing_area);
    }

    // Update cursor
    if (eq->hovered_band >= 0 || eq->dragged_band >= 0) {
        gtk_widget_set_cursor_from_name(eq->drawing_area, "grab");
    } else {
        gtk_widget_set_cursor(eq->drawing_area, NULL);
    }
}

// Press handler for starting drag
static void on_press(GtkGestureClick *gesture, int n_press, double x, double y, gpointer user_data) {
    (void)gesture;
    (void)n_press;
    ParametricEQEditor *eq = (ParametricEQEditor *)user_data;
    if (!eq || !eq->drawing_area) return;

    int width = gtk_widget_get_width(eq->drawing_area);
    int height = gtk_widget_get_height(eq->drawing_area);

    int band = find_band_at(eq, x, y, width, height);
    if (band >= 0) {
        eq->dragged_band = band;
        eq->drag_start_x = x;
        eq->drag_start_y = y;
        eq->drag_start_freq = eq->band_freq[band];
        eq->drag_start_gain = eq->band_gain[band];
        gtk_widget_set_cursor_from_name(eq->drawing_area, "grabbing");
        gtk_widget_queue_draw(eq->drawing_area);
    }
}

// Release handler
static void on_release(GtkGestureClick *gesture, int n_press, double x, double y, gpointer user_data) {
    (void)gesture;
    (void)n_press;
    (void)x;
    (void)y;
    ParametricEQEditor *eq = (ParametricEQEditor *)user_data;
    if (!eq) return;

    if (eq->dragged_band >= 0) {
        eq->dragged_band = -1;
        gtk_widget_set_cursor_from_name(eq->drawing_area, eq->hovered_band >= 0 ? "grab" : "default");
        gtk_widget_queue_draw(eq->drawing_area);
    }
}

// Drag handler for moving bands
static void on_drag(GtkGestureDrag *gesture, double offset_x, double offset_y, gpointer user_data) {
    (void)gesture;
    ParametricEQEditor *eq = (ParametricEQEditor *)user_data;
    if (!eq || eq->dragged_band < 0) return;

    int width = gtk_widget_get_width(eq->drawing_area);
    int height = gtk_widget_get_height(eq->drawing_area);

    // Calculate new position
    double new_x = eq->drag_start_x + offset_x;
    double new_y = eq->drag_start_y + offset_y;

    double new_freq = x_to_freq(new_x, width);
    double new_gain = y_to_gain(new_y, height);

    // Get frequency limits based on band type
    float freq_min, freq_max;
    int param_base = eq->dragged_band * 3;

    freq_min = effect_get_param_min(eq->audio_engine, eq->track, eq->effect_slot, param_base);
    freq_max = effect_get_param_max(eq->audio_engine, eq->track, eq->effect_slot, param_base);

    // Clamp values
    new_freq = fmax(freq_min, fmin(freq_max, new_freq));
    new_gain = fmax(-18.0, fmin(18.0, new_gain));

    // Update engine
    effect_set_param_value(eq->audio_engine, eq->track, eq->effect_slot, param_base, new_freq);
    effect_set_param_value(eq->audio_engine, eq->track, eq->effect_slot, param_base + 1, new_gain);

    // Update local cache
    eq->band_freq[eq->dragged_band] = new_freq;
    eq->band_gain[eq->dragged_band] = new_gain;

    // Redraw
    gtk_widget_queue_draw(eq->drawing_area);
}

// Scroll handler for Q adjustment
static gboolean on_scroll(GtkEventControllerScroll *controller, double dx, double dy, gpointer user_data) {
    (void)controller;
    (void)dx;
    ParametricEQEditor *eq = (ParametricEQEditor *)user_data;
    if (!eq || eq->hovered_band < 0) return FALSE;

    int band = eq->hovered_band;
    int param_index = band * 3 + 2;  // Q parameter

    float current_q = eq->band_q[band];
    float min_q = effect_get_param_min(eq->audio_engine, eq->track, eq->effect_slot, param_index);
    float max_q = effect_get_param_max(eq->audio_engine, eq->track, eq->effect_slot, param_index);

    // Adjust Q (multiply/divide for log-like feel)
    float factor = (dy > 0) ? 0.9f : 1.1f;
    float new_q = current_q * factor;
    new_q = fmaxf(min_q, fminf(max_q, new_q));

    // Update engine
    effect_set_param_value(eq->audio_engine, eq->track, eq->effect_slot, param_index, new_q);
    eq->band_q[band] = new_q;

    gtk_widget_queue_draw(eq->drawing_area);

    return TRUE;
}

// Parameter slider callback
static void on_param_changed(float value, int param_index, void *user_data) {
    ParametricEQEditor *eq = (ParametricEQEditor *)user_data;
    if (!eq) return;

    effect_set_param_value(eq->audio_engine, eq->track, eq->effect_slot, param_index, value);

    // Update local cache
    int band = param_index / 3;
    int param_type = param_index % 3;

    if (param_index == 12) {
        eq->output_gain = value;
    } else if (band < 4) {
        switch (param_type) {
            case 0: eq->band_freq[band] = value; break;
            case 1: eq->band_gain[band] = value; break;
            case 2: eq->band_q[band] = value; break;
        }
    }

    gtk_widget_queue_draw(eq->drawing_area);
}

// Update parameters from engine
static void update_params_from_engine(ParametricEQEditor *eq) {
    for (int band = 0; band < 4; band++) {
        int base = band * 3;
        eq->band_freq[band] = effect_get_param_value(eq->audio_engine, eq->track, eq->effect_slot, base);
        eq->band_gain[band] = effect_get_param_value(eq->audio_engine, eq->track, eq->effect_slot, base + 1);
        eq->band_q[band] = effect_get_param_value(eq->audio_engine, eq->track, eq->effect_slot, base + 2);
    }
    eq->output_gain = effect_get_param_value(eq->audio_engine, eq->track, eq->effect_slot, 12);
}

// Create band controls section
static GtkWidget* create_band_controls(ParametricEQEditor *eq, int band, const char *name) {
    GtkWidget *frame = gtk_frame_new(name);
    gtk_widget_add_css_class(frame, "card");

    GtkWidget *grid = gtk_grid_new();
    gtk_grid_set_row_spacing(GTK_GRID(grid), 4);
    gtk_grid_set_column_spacing(GTK_GRID(grid), 8);
    gtk_widget_set_margin_start(grid, 8);
    gtk_widget_set_margin_end(grid, 8);
    gtk_widget_set_margin_top(grid, 4);
    gtk_widget_set_margin_bottom(grid, 8);

    int base = band * 3;

    // Frequency
    float freq = effect_get_param_value(eq->audio_engine, eq->track, eq->effect_slot, base);
    float freq_min = effect_get_param_min(eq->audio_engine, eq->track, eq->effect_slot, base);
    float freq_max = effect_get_param_max(eq->audio_engine, eq->track, eq->effect_slot, base);

    GtkWidget *freq_widget = daw_small_knob_new("Freq", freq, freq_min, freq_max, "Hz", base, on_param_changed, eq);
    gtk_grid_attach(GTK_GRID(grid), freq_widget, 0, 0, 1, 1);
    eq->freq_sliders[band] = freq_widget;

    // Gain
    float gain = effect_get_param_value(eq->audio_engine, eq->track, eq->effect_slot, base + 1);
    GtkWidget *gain_widget = daw_small_knob_new("Gain", gain, -18.0, 18.0, "dB", base + 1, on_param_changed, eq);
    gtk_grid_attach(GTK_GRID(grid), gain_widget, 1, 0, 1, 1);
    eq->gain_sliders[band] = gain_widget;

    // Q
    float q = effect_get_param_value(eq->audio_engine, eq->track, eq->effect_slot, base + 2);
    float q_min = effect_get_param_min(eq->audio_engine, eq->track, eq->effect_slot, base + 2);
    float q_max = effect_get_param_max(eq->audio_engine, eq->track, eq->effect_slot, base + 2);

    GtkWidget *q_widget = daw_small_knob_new("Q", q, q_min, q_max, "", base + 2, on_param_changed, eq);
    gtk_grid_attach(GTK_GRID(grid), q_widget, 2, 0, 1, 1);
    eq->q_sliders[band] = q_widget;

    gtk_frame_set_child(GTK_FRAME(frame), grid);
    return frame;
}

// Create the EQ editor
GtkWidget* parametric_eq_editor_new(void *audio_engine, int track, int effect_slot) {
    ParametricEQEditor *eq = malloc(sizeof(ParametricEQEditor));
    if (!eq) return NULL;

    memset(eq, 0, sizeof(ParametricEQEditor));
    eq->audio_engine = audio_engine;
    eq->track = track;
    eq->effect_slot = effect_slot;
    eq->hovered_band = -1;
    eq->dragged_band = -1;

    // Load initial parameters
    update_params_from_engine(eq);

    // Main container
    eq->container = gtk_box_new(GTK_ORIENTATION_VERTICAL, 8);
    gtk_widget_set_margin_start(eq->container, 8);
    gtk_widget_set_margin_end(eq->container, 8);
    gtk_widget_set_margin_top(eq->container, 8);
    gtk_widget_set_margin_bottom(eq->container, 8);

    // Store eq pointer for later access
    g_object_set_data_full(G_OBJECT(eq->container), "eq-editor", eq, (GDestroyNotify)free);

    // Title
    GtkWidget *title = gtk_label_new(NULL);
    gtk_label_set_markup(GTK_LABEL(title),
        "<span foreground='#7dcfff' weight='bold' size='large'>Parametric EQ</span>");
    gtk_widget_set_halign(title, GTK_ALIGN_START);
    gtk_box_append(GTK_BOX(eq->container), title);

    // Drawing area for frequency response
    eq->drawing_area = gtk_drawing_area_new();
    gtk_widget_set_size_request(eq->drawing_area, EQ_WIDTH, EQ_HEIGHT);
    gtk_widget_set_hexpand(eq->drawing_area, TRUE);
    gtk_drawing_area_set_draw_func(GTK_DRAWING_AREA(eq->drawing_area), on_draw, eq, NULL);

    // Add event controllers
    GtkEventController *motion = gtk_event_controller_motion_new();
    g_signal_connect(motion, "motion", G_CALLBACK(on_motion), eq);
    gtk_widget_add_controller(eq->drawing_area, motion);

    GtkGesture *click = gtk_gesture_click_new();
    g_signal_connect(click, "pressed", G_CALLBACK(on_press), eq);
    g_signal_connect(click, "released", G_CALLBACK(on_release), eq);
    gtk_widget_add_controller(eq->drawing_area, GTK_EVENT_CONTROLLER(click));

    GtkGesture *drag = gtk_gesture_drag_new();
    g_signal_connect(drag, "drag-update", G_CALLBACK(on_drag), eq);
    gtk_widget_add_controller(eq->drawing_area, GTK_EVENT_CONTROLLER(drag));

    GtkEventController *scroll = gtk_event_controller_scroll_new(GTK_EVENT_CONTROLLER_SCROLL_VERTICAL);
    g_signal_connect(scroll, "scroll", G_CALLBACK(on_scroll), eq);
    gtk_widget_add_controller(eq->drawing_area, scroll);

    gtk_box_append(GTK_BOX(eq->container), eq->drawing_area);

    // Hint label
    GtkWidget *hint = gtk_label_new("Drag nodes to adjust frequency/gain. Scroll over node to adjust Q.");
    gtk_widget_set_opacity(hint, 0.6);
    gtk_widget_set_halign(hint, GTK_ALIGN_CENTER);
    gtk_widget_set_margin_top(hint, 4);
    gtk_box_append(GTK_BOX(eq->container), hint);

    // Band controls
    eq->controls_box = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 12);
    gtk_widget_set_halign(eq->controls_box, GTK_ALIGN_CENTER);
    gtk_widget_set_margin_top(eq->controls_box, 8);

    const char *band_names[] = {"Low", "Mid 1", "Mid 2", "High"};
    for (int i = 0; i < 4; i++) {
        GtkWidget *band_ctrl = create_band_controls(eq, i, band_names[i]);
        gtk_box_append(GTK_BOX(eq->controls_box), band_ctrl);
    }

    // Output gain
    GtkWidget *output_frame = gtk_frame_new("Output");
    gtk_widget_add_css_class(output_frame, "card");

    float out_gain = effect_get_param_value(audio_engine, track, effect_slot, 12);
    GtkWidget *output_knob = daw_small_knob_new("Level", out_gain, -12.0, 12.0, "dB", 12, on_param_changed, eq);
    gtk_widget_set_margin_start(output_knob, 8);
    gtk_widget_set_margin_end(output_knob, 8);
    gtk_widget_set_margin_top(output_knob, 4);
    gtk_widget_set_margin_bottom(output_knob, 8);
    gtk_frame_set_child(GTK_FRAME(output_frame), output_knob);
    eq->output_slider = output_knob;

    gtk_box_append(GTK_BOX(eq->controls_box), output_frame);
    gtk_box_append(GTK_BOX(eq->container), eq->controls_box);

    return eq->container;
}

void parametric_eq_editor_refresh(GtkWidget *editor) {
    if (!editor) return;
    ParametricEQEditor *eq = g_object_get_data(G_OBJECT(editor), "eq-editor");
    if (!eq) return;

    update_params_from_engine(eq);
    gtk_widget_queue_draw(eq->drawing_area);
}

void parametric_eq_editor_set_slot(GtkWidget *editor, int slot) {
    if (!editor) return;
    ParametricEQEditor *eq = g_object_get_data(G_OBJECT(editor), "eq-editor");
    if (!eq) return;

    eq->effect_slot = slot;
    update_params_from_engine(eq);
    gtk_widget_queue_draw(eq->drawing_area);
}
