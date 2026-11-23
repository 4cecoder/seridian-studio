/**
 * Pro EQ Editor - FabFilter Pro-Q Style Visual Parametric EQ
 */

#include "pro_eq_editor.h"
#include "effects_chain_gtk.h"
#include "daw_widgets.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>

// Portable M_PI definition
#ifndef M_PI
#define M_PI 3.14159265358979323846
#endif

#define MAX_BANDS 8
#define PARAMS_PER_BAND 6
#define CURVE_POINTS 512

// Filter type names
static const char *filter_type_names[] = {
    "Bell", "Low Shelf", "High Shelf", "Low Cut", "High Cut", "Notch", "Band Pass"
};

// Band colors (vibrant, FabFilter-inspired)
static const double band_colors[][3] = {
    {0.91, 0.30, 0.24},  // Band 0: Red
    {0.95, 0.61, 0.07},  // Band 1: Orange
    {0.95, 0.77, 0.06},  // Band 2: Yellow
    {0.18, 0.80, 0.44},  // Band 3: Green
    {0.20, 0.60, 0.86},  // Band 4: Blue
    {0.61, 0.35, 0.71},  // Band 5: Purple
    {0.91, 0.30, 0.60},  // Band 6: Pink
    {0.33, 0.80, 0.76},  // Band 7: Cyan
};

typedef struct {
    float frequency;
    float gain;
    float q;
    int filter_type;
    int enabled;
    int solo;

    // For magnitude calculation
    float b0, b1, b2, a1, a2;
} BandState;

typedef struct {
    GtkWidget *main_box;
    GtkWidget *curve_area;
    GtkWidget *bands_box;

    // Band control widgets
    GtkWidget *band_frames[MAX_BANDS];
    GtkWidget *freq_knobs[MAX_BANDS];
    GtkWidget *gain_knobs[MAX_BANDS];
    GtkWidget *q_knobs[MAX_BANDS];
    GtkWidget *type_dropdowns[MAX_BANDS];
    GtkWidget *enable_buttons[MAX_BANDS];
    GtkWidget *solo_buttons[MAX_BANDS];

    // State
    void *audio_engine;
    int track;
    int effect_slot;
    float sample_rate;

    BandState bands[MAX_BANDS];

    // Interaction
    int dragging_band;
    int hovering_band;
    double drag_start_x;
    double drag_start_y;
    float drag_start_freq;
    float drag_start_gain;

    // Curve data
    float curve_magnitude[CURVE_POINTS];
} ProEQEditor;

// Forward declarations
static void update_curve(ProEQEditor *editor);
static void draw_curve(GtkDrawingArea *area, cairo_t *cr, int width, int height, gpointer user_data);
static void on_band_param_changed(float value, int param_index, void *user_data);
static gboolean on_curve_click(GtkGestureClick *gesture, int n_press, double x, double y, gpointer user_data);
static void on_curve_drag_begin(GtkGestureDrag *gesture, double x, double y, gpointer user_data);
static void on_curve_drag_update(GtkGestureDrag *gesture, double offset_x, double offset_y, gpointer user_data);
static void on_curve_drag_end(GtkGestureDrag *gesture, double offset_x, double offset_y, gpointer user_data);
static gboolean on_curve_scroll(GtkEventControllerScroll *controller, double dx, double dy, gpointer user_data);
static void on_curve_motion(GtkEventControllerMotion *controller, double x, double y, gpointer user_data);

// Frequency <-> X coordinate conversions (log scale)
static double freq_to_x(float freq, int width) {
    // Log scale: 20Hz - 20kHz
    double log_min = log10(20.0);
    double log_max = log10(20000.0);
    double log_freq = log10(fmax(20.0, fmin(20000.0, freq)));
    return (log_freq - log_min) / (log_max - log_min) * width;
}

static float x_to_freq(double x, int width) {
    double log_min = log10(20.0);
    double log_max = log10(20000.0);
    double norm = fmax(0.0, fmin(1.0, x / width));
    double log_freq = log_min + norm * (log_max - log_min);
    return (float)pow(10.0, log_freq);
}

// Gain <-> Y coordinate conversions
static double gain_to_y(float gain, int height) {
    // -30dB to +30dB, inverted (top = +30, bottom = -30)
    return (1.0 - (gain + 30.0) / 60.0) * height;
}

static float y_to_gain(double y, int height) {
    return (float)((1.0 - y / height) * 60.0 - 30.0);
}

// Calculate biquad magnitude at frequency
static float calculate_band_magnitude(BandState *band, float freq, float sample_rate) {
    if (!band->enabled) return 1.0f;

    double omega = 2.0 * M_PI * freq / sample_rate;
    double cos_w = cos(omega);
    double cos_2w = cos(2.0 * omega);
    double sin_w = sin(omega);
    double sin_2w = sin(2.0 * omega);

    double num_real = band->b0 + band->b1 * cos_w + band->b2 * cos_2w;
    double num_imag = -band->b1 * sin_w - band->b2 * sin_2w;
    double den_real = 1.0 + band->a1 * cos_w + band->a2 * cos_2w;
    double den_imag = -band->a1 * sin_w - band->a2 * sin_2w;

    double num_mag_sq = num_real * num_real + num_imag * num_imag;
    double den_mag_sq = den_real * den_real + den_imag * den_imag;

    if (den_mag_sq < 1e-10) return 1.0f;
    return (float)sqrt(num_mag_sq / den_mag_sq);
}

// Update band coefficients from parameters
static void update_band_coefficients(BandState *band, float sample_rate) {
    if (!band->enabled) {
        band->b0 = 1.0f; band->b1 = 0.0f; band->b2 = 0.0f;
        band->a1 = 0.0f; band->a2 = 0.0f;
        return;
    }

    float freq = fmaxf(20.0f, fminf(sample_rate * 0.45f, band->frequency));
    float q = fmaxf(0.1f, band->q);
    float gain = band->gain;

    float omega = 2.0f * (float)M_PI * freq / sample_rate;
    float sin_omega = sinf(omega);
    float cos_omega = cosf(omega);
    float alpha = sin_omega / (2.0f * q);
    float A = powf(10.0f, gain / 40.0f);
    float sq_a = sqrtf(A);

    float b0, b1, b2, a0, a1, a2;

    switch (band->filter_type) {
        case 0: // Bell
            b0 = 1.0f + alpha * A;
            b1 = -2.0f * cos_omega;
            b2 = 1.0f - alpha * A;
            a0 = 1.0f + alpha / A;
            a1 = -2.0f * cos_omega;
            a2 = 1.0f - alpha / A;
            break;
        case 1: // Low Shelf
            b0 = A * ((A + 1.0f) - (A - 1.0f) * cos_omega + 2.0f * sq_a * alpha);
            b1 = 2.0f * A * ((A - 1.0f) - (A + 1.0f) * cos_omega);
            b2 = A * ((A + 1.0f) - (A - 1.0f) * cos_omega - 2.0f * sq_a * alpha);
            a0 = (A + 1.0f) + (A - 1.0f) * cos_omega + 2.0f * sq_a * alpha;
            a1 = -2.0f * ((A - 1.0f) + (A + 1.0f) * cos_omega);
            a2 = (A + 1.0f) + (A - 1.0f) * cos_omega - 2.0f * sq_a * alpha;
            break;
        case 2: // High Shelf
            b0 = A * ((A + 1.0f) + (A - 1.0f) * cos_omega + 2.0f * sq_a * alpha);
            b1 = -2.0f * A * ((A - 1.0f) + (A + 1.0f) * cos_omega);
            b2 = A * ((A + 1.0f) + (A - 1.0f) * cos_omega - 2.0f * sq_a * alpha);
            a0 = (A + 1.0f) - (A - 1.0f) * cos_omega + 2.0f * sq_a * alpha;
            a1 = 2.0f * ((A - 1.0f) - (A + 1.0f) * cos_omega);
            a2 = (A + 1.0f) - (A - 1.0f) * cos_omega - 2.0f * sq_a * alpha;
            break;
        case 3: // Low Cut (HPF)
            b0 = (1.0f + cos_omega) / 2.0f;
            b1 = -(1.0f + cos_omega);
            b2 = (1.0f + cos_omega) / 2.0f;
            a0 = 1.0f + alpha;
            a1 = -2.0f * cos_omega;
            a2 = 1.0f - alpha;
            break;
        case 4: // High Cut (LPF)
            b0 = (1.0f - cos_omega) / 2.0f;
            b1 = 1.0f - cos_omega;
            b2 = (1.0f - cos_omega) / 2.0f;
            a0 = 1.0f + alpha;
            a1 = -2.0f * cos_omega;
            a2 = 1.0f - alpha;
            break;
        case 5: // Notch
            b0 = 1.0f;
            b1 = -2.0f * cos_omega;
            b2 = 1.0f;
            a0 = 1.0f + alpha;
            a1 = -2.0f * cos_omega;
            a2 = 1.0f - alpha;
            break;
        case 6: // Band Pass
            b0 = alpha;
            b1 = 0.0f;
            b2 = -alpha;
            a0 = 1.0f + alpha;
            a1 = -2.0f * cos_omega;
            a2 = 1.0f - alpha;
            break;
        default:
            b0 = 1.0f; b1 = 0.0f; b2 = 0.0f;
            a0 = 1.0f; a1 = 0.0f; a2 = 0.0f;
    }

    // Normalize
    band->b0 = b0 / a0;
    band->b1 = b1 / a0;
    band->b2 = b2 / a0;
    band->a1 = a1 / a0;
    band->a2 = a2 / a0;
}

// Sync state from audio engine
static void sync_from_engine(ProEQEditor *editor) {
    for (int i = 0; i < MAX_BANDS; i++) {
        int base = i * PARAMS_PER_BAND;
        editor->bands[i].frequency = effect_get_param_value(editor->audio_engine, editor->track, editor->effect_slot, base + 0);
        editor->bands[i].gain = effect_get_param_value(editor->audio_engine, editor->track, editor->effect_slot, base + 1);
        editor->bands[i].q = effect_get_param_value(editor->audio_engine, editor->track, editor->effect_slot, base + 2);
        editor->bands[i].filter_type = (int)effect_get_param_value(editor->audio_engine, editor->track, editor->effect_slot, base + 3);
        editor->bands[i].enabled = effect_get_param_value(editor->audio_engine, editor->track, editor->effect_slot, base + 4) >= 0.5f;
        editor->bands[i].solo = effect_get_param_value(editor->audio_engine, editor->track, editor->effect_slot, base + 5) >= 0.5f;

        update_band_coefficients(&editor->bands[i], editor->sample_rate);
    }
}

// Update the curve data
static void update_curve(ProEQEditor *editor) {
    // Check for any solo band
    int any_solo = 0;
    for (int i = 0; i < MAX_BANDS; i++) {
        if (editor->bands[i].solo && editor->bands[i].enabled) {
            any_solo = 1;
            break;
        }
    }

    // Calculate combined magnitude at each frequency point
    for (int i = 0; i < CURVE_POINTS; i++) {
        double norm = (double)i / (CURVE_POINTS - 1);
        double log_freq = log10(20.0) + norm * (log10(20000.0) - log10(20.0));
        float freq = (float)pow(10.0, log_freq);

        float magnitude = 1.0f;
        for (int b = 0; b < MAX_BANDS; b++) {
            if (!editor->bands[b].enabled) continue;
            if (any_solo && !editor->bands[b].solo) continue;
            magnitude *= calculate_band_magnitude(&editor->bands[b], freq, editor->sample_rate);
        }
        editor->curve_magnitude[i] = magnitude;
    }

    // Redraw
    gtk_widget_queue_draw(editor->curve_area);
}

// Draw the frequency response curve
static void draw_curve(GtkDrawingArea *area, cairo_t *cr, int width, int height, gpointer user_data) {
    (void)area;
    ProEQEditor *editor = (ProEQEditor *)user_data;

    // Background gradient
    cairo_pattern_t *bg_grad = cairo_pattern_create_linear(0, 0, 0, height);
    cairo_pattern_add_color_stop_rgb(bg_grad, 0.0, 0.08, 0.08, 0.12);
    cairo_pattern_add_color_stop_rgb(bg_grad, 1.0, 0.04, 0.04, 0.06);
    cairo_set_source(cr, bg_grad);
    cairo_paint(cr);
    cairo_pattern_destroy(bg_grad);

    // Grid lines
    cairo_set_line_width(cr, 0.5);

    // Frequency grid (log scale)
    float freq_lines[] = {20, 50, 100, 200, 500, 1000, 2000, 5000, 10000, 20000};
    for (int i = 0; i < 10; i++) {
        double x = freq_to_x(freq_lines[i], width);
        cairo_set_source_rgba(cr, 0.3, 0.3, 0.35, 0.4);
        cairo_move_to(cr, x, 0);
        cairo_line_to(cr, x, height);
        cairo_stroke(cr);

        // Labels for major frequencies
        if (freq_lines[i] == 100 || freq_lines[i] == 1000 || freq_lines[i] == 10000) {
            cairo_set_source_rgba(cr, 0.5, 0.5, 0.55, 0.8);
            cairo_select_font_face(cr, "Sans", CAIRO_FONT_SLANT_NORMAL, CAIRO_FONT_WEIGHT_NORMAL);
            cairo_set_font_size(cr, 10);
            char label[16];
            if (freq_lines[i] >= 1000) {
                snprintf(label, sizeof(label), "%dk", (int)(freq_lines[i] / 1000));
            } else {
                snprintf(label, sizeof(label), "%d", (int)freq_lines[i]);
            }
            cairo_move_to(cr, x + 2, height - 4);
            cairo_show_text(cr, label);
        }
    }

    // dB grid
    for (int db = -24; db <= 24; db += 6) {
        double y = gain_to_y((float)db, height);
        if (db == 0) {
            cairo_set_source_rgba(cr, 0.4, 0.4, 0.45, 0.6);
            cairo_set_line_width(cr, 1.0);
        } else {
            cairo_set_source_rgba(cr, 0.25, 0.25, 0.30, 0.4);
            cairo_set_line_width(cr, 0.5);
        }
        cairo_move_to(cr, 0, y);
        cairo_line_to(cr, width, y);
        cairo_stroke(cr);

        // dB labels
        if (db % 12 == 0) {
            cairo_set_source_rgba(cr, 0.5, 0.5, 0.55, 0.8);
            cairo_set_font_size(cr, 10);
            char label[8];
            snprintf(label, sizeof(label), "%+d", db);
            cairo_move_to(cr, 4, y - 2);
            cairo_show_text(cr, label);
        }
    }

    // Draw the combined frequency response curve with gradient fill
    cairo_move_to(cr, 0, gain_to_y(0, height));
    for (int i = 0; i < CURVE_POINTS; i++) {
        double x = (double)i / (CURVE_POINTS - 1) * width;
        float db = 20.0f * log10f(fmaxf(0.001f, editor->curve_magnitude[i]));
        db = fmaxf(-30.0f, fminf(30.0f, db));
        double y = gain_to_y(db, height);
        if (i == 0) {
            cairo_move_to(cr, x, y);
        } else {
            cairo_line_to(cr, x, y);
        }
    }

    // Fill below curve
    cairo_line_to(cr, width, gain_to_y(0, height));
    cairo_line_to(cr, 0, gain_to_y(0, height));
    cairo_close_path(cr);

    // Gradient fill for curve area
    cairo_pattern_t *fill_grad = cairo_pattern_create_linear(0, 0, 0, height);
    cairo_pattern_add_color_stop_rgba(fill_grad, 0.0, 0.33, 0.8, 0.76, 0.3);
    cairo_pattern_add_color_stop_rgba(fill_grad, 0.5, 0.33, 0.8, 0.76, 0.1);
    cairo_pattern_add_color_stop_rgba(fill_grad, 1.0, 0.33, 0.8, 0.76, 0.05);
    cairo_set_source(cr, fill_grad);
    cairo_fill_preserve(cr);
    cairo_pattern_destroy(fill_grad);

    // Curve stroke
    cairo_set_source_rgba(cr, 0.33, 0.9, 0.85, 1.0);
    cairo_set_line_width(cr, 2.0);
    cairo_stroke(cr);

    // Draw band nodes
    for (int i = 0; i < MAX_BANDS; i++) {
        if (!editor->bands[i].enabled) continue;

        double x = freq_to_x(editor->bands[i].frequency, width);
        double y = gain_to_y(editor->bands[i].gain, height);

        // Node glow
        if (i == editor->hovering_band || i == editor->dragging_band) {
            cairo_arc(cr, x, y, 16, 0, 2 * M_PI);
            cairo_set_source_rgba(cr, band_colors[i][0], band_colors[i][1], band_colors[i][2], 0.3);
            cairo_fill(cr);
        }

        // Node circle
        cairo_arc(cr, x, y, 10, 0, 2 * M_PI);
        cairo_set_source_rgba(cr, band_colors[i][0], band_colors[i][1], band_colors[i][2], 0.9);
        cairo_fill_preserve(cr);
        cairo_set_source_rgba(cr, 1, 1, 1, 0.8);
        cairo_set_line_width(cr, 1.5);
        cairo_stroke(cr);

        // Band number
        cairo_set_source_rgba(cr, 1, 1, 1, 0.9);
        cairo_set_font_size(cr, 11);
        char num[4];
        snprintf(num, sizeof(num), "%d", i + 1);
        cairo_text_extents_t extents;
        cairo_text_extents(cr, num, &extents);
        cairo_move_to(cr, x - extents.width / 2, y + extents.height / 2 - 1);
        cairo_show_text(cr, num);

        // Q indicator (arc around node)
        double q_angle = M_PI * (1.0 - fminf(editor->bands[i].q, 10.0f) / 10.0f);
        cairo_arc(cr, x, y, 13, -M_PI/2 - q_angle/2, -M_PI/2 + q_angle/2);
        cairo_set_source_rgba(cr, band_colors[i][0], band_colors[i][1], band_colors[i][2], 0.6);
        cairo_set_line_width(cr, 2);
        cairo_stroke(cr);
    }
}

// Find band at position
static int find_band_at(ProEQEditor *editor, double x, double y, int width, int height) {
    for (int i = 0; i < MAX_BANDS; i++) {
        if (!editor->bands[i].enabled) continue;

        double bx = freq_to_x(editor->bands[i].frequency, width);
        double by = gain_to_y(editor->bands[i].gain, height);

        double dist = sqrt((x - bx) * (x - bx) + (y - by) * (y - by));
        if (dist < 15) return i;
    }
    return -1;
}

// Gesture callbacks
static gboolean on_curve_click(GtkGestureClick *gesture, int n_press, double x, double y, gpointer user_data) {
    ProEQEditor *editor = (ProEQEditor *)user_data;
    int width = gtk_widget_get_width(editor->curve_area);
    int height = gtk_widget_get_height(editor->curve_area);

    int button = gtk_gesture_single_get_current_button(GTK_GESTURE_SINGLE(gesture));

    if (button == 3) { // Right click - toggle band enable
        int band = find_band_at(editor, x, y, width, height);
        if (band >= 0) {
            int base = band * PARAMS_PER_BAND;
            float new_val = editor->bands[band].enabled ? 0.0f : 1.0f;
            effect_set_param_value(editor->audio_engine, editor->track, editor->effect_slot, base + 4, new_val);
            sync_from_engine(editor);
            update_curve(editor);
        }
        return TRUE;
    }

    if (n_press == 2) { // Double-click - toggle band or add new
        int band = find_band_at(editor, x, y, width, height);
        if (band >= 0) {
            // Toggle enable
            int base = band * PARAMS_PER_BAND;
            float new_val = editor->bands[band].enabled ? 0.0f : 1.0f;
            effect_set_param_value(editor->audio_engine, editor->track, editor->effect_slot, base + 4, new_val);
        } else {
            // Add new band at this position - find first disabled band
            for (int i = 0; i < MAX_BANDS; i++) {
                if (!editor->bands[i].enabled) {
                    int base = i * PARAMS_PER_BAND;
                    float freq = x_to_freq(x, width);
                    float gain = y_to_gain(y, height);
                    effect_set_param_value(editor->audio_engine, editor->track, editor->effect_slot, base + 0, freq);
                    effect_set_param_value(editor->audio_engine, editor->track, editor->effect_slot, base + 1, gain);
                    effect_set_param_value(editor->audio_engine, editor->track, editor->effect_slot, base + 3, 0); // Bell
                    effect_set_param_value(editor->audio_engine, editor->track, editor->effect_slot, base + 4, 1.0f); // Enable
                    break;
                }
            }
        }
        sync_from_engine(editor);
        update_curve(editor);
    }

    return TRUE;
}

static void on_curve_drag_begin(GtkGestureDrag *gesture, double x, double y, gpointer user_data) {
    (void)gesture;
    ProEQEditor *editor = (ProEQEditor *)user_data;
    int width = gtk_widget_get_width(editor->curve_area);
    int height = gtk_widget_get_height(editor->curve_area);

    int band = find_band_at(editor, x, y, width, height);
    if (band >= 0) {
        editor->dragging_band = band;
        editor->drag_start_x = x;
        editor->drag_start_y = y;
        editor->drag_start_freq = editor->bands[band].frequency;
        editor->drag_start_gain = editor->bands[band].gain;
        gtk_widget_queue_draw(editor->curve_area);
    }
}

static void on_curve_drag_update(GtkGestureDrag *gesture, double offset_x, double offset_y, gpointer user_data) {
    (void)gesture;
    ProEQEditor *editor = (ProEQEditor *)user_data;

    if (editor->dragging_band < 0) return;

    int width = gtk_widget_get_width(editor->curve_area);
    int height = gtk_widget_get_height(editor->curve_area);
    int band = editor->dragging_band;

    double new_x = editor->drag_start_x + offset_x;
    double new_y = editor->drag_start_y + offset_y;

    float new_freq = x_to_freq(new_x, width);
    float new_gain = y_to_gain(new_y, height);

    new_freq = fmaxf(20.0f, fminf(20000.0f, new_freq));
    new_gain = fmaxf(-30.0f, fminf(30.0f, new_gain));

    int base = band * PARAMS_PER_BAND;
    effect_set_param_value(editor->audio_engine, editor->track, editor->effect_slot, base + 0, new_freq);
    effect_set_param_value(editor->audio_engine, editor->track, editor->effect_slot, base + 1, new_gain);

    sync_from_engine(editor);
    update_curve(editor);
}

static void on_curve_drag_end(GtkGestureDrag *gesture, double offset_x, double offset_y, gpointer user_data) {
    (void)gesture;
    (void)offset_x;
    (void)offset_y;
    ProEQEditor *editor = (ProEQEditor *)user_data;
    editor->dragging_band = -1;
    gtk_widget_queue_draw(editor->curve_area);
}

static gboolean on_curve_scroll(GtkEventControllerScroll *controller, double dx, double dy, gpointer user_data) {
    (void)controller;
    (void)dx;
    ProEQEditor *editor = (ProEQEditor *)user_data;

    if (editor->hovering_band < 0) return FALSE;

    int band = editor->hovering_band;
    int base = band * PARAMS_PER_BAND;

    float q = editor->bands[band].q;
    float delta = (float)dy * -0.2f;
    q = fmaxf(0.1f, fminf(30.0f, q + delta * q));

    effect_set_param_value(editor->audio_engine, editor->track, editor->effect_slot, base + 2, q);

    sync_from_engine(editor);
    update_curve(editor);
    return TRUE;
}

static void on_curve_motion(GtkEventControllerMotion *controller, double x, double y, gpointer user_data) {
    (void)controller;
    ProEQEditor *editor = (ProEQEditor *)user_data;
    int width = gtk_widget_get_width(editor->curve_area);
    int height = gtk_widget_get_height(editor->curve_area);

    int old_hover = editor->hovering_band;
    editor->hovering_band = find_band_at(editor, x, y, width, height);

    if (old_hover != editor->hovering_band) {
        gtk_widget_queue_draw(editor->curve_area);
    }
}

// Band control callbacks
static void on_band_enable_toggled(GtkToggleButton *button, gpointer user_data) {
    ProEQEditor *editor = (ProEQEditor *)user_data;
    int band = GPOINTER_TO_INT(g_object_get_data(G_OBJECT(button), "band"));

    gboolean active = gtk_toggle_button_get_active(button);
    int base = band * PARAMS_PER_BAND;
    effect_set_param_value(editor->audio_engine, editor->track, editor->effect_slot, base + 4, active ? 1.0f : 0.0f);

    sync_from_engine(editor);
    update_curve(editor);
}

static void on_band_solo_toggled(GtkToggleButton *button, gpointer user_data) {
    ProEQEditor *editor = (ProEQEditor *)user_data;
    int band = GPOINTER_TO_INT(g_object_get_data(G_OBJECT(button), "band"));

    gboolean active = gtk_toggle_button_get_active(button);
    int base = band * PARAMS_PER_BAND;
    effect_set_param_value(editor->audio_engine, editor->track, editor->effect_slot, base + 5, active ? 1.0f : 0.0f);

    sync_from_engine(editor);
    update_curve(editor);
}

static void on_type_changed(GtkDropDown *dropdown, GParamSpec *pspec, gpointer user_data) {
    (void)pspec;
    ProEQEditor *editor = (ProEQEditor *)user_data;
    int band = GPOINTER_TO_INT(g_object_get_data(G_OBJECT(dropdown), "band"));

    guint selected = gtk_drop_down_get_selected(dropdown);
    int base = band * PARAMS_PER_BAND;
    effect_set_param_value(editor->audio_engine, editor->track, editor->effect_slot, base + 3, (float)selected);

    sync_from_engine(editor);
    update_curve(editor);
}

static void on_freq_changed(float value, int param_index, void *user_data) {
    ProEQEditor *editor = (ProEQEditor *)user_data;
    int band = param_index;
    int base = band * PARAMS_PER_BAND;
    effect_set_param_value(editor->audio_engine, editor->track, editor->effect_slot, base + 0, value);
    sync_from_engine(editor);
    update_curve(editor);
}

static void on_gain_changed(float value, int param_index, void *user_data) {
    ProEQEditor *editor = (ProEQEditor *)user_data;
    int band = param_index;
    int base = band * PARAMS_PER_BAND;
    effect_set_param_value(editor->audio_engine, editor->track, editor->effect_slot, base + 1, value);
    sync_from_engine(editor);
    update_curve(editor);
}

static void on_q_changed(float value, int param_index, void *user_data) {
    ProEQEditor *editor = (ProEQEditor *)user_data;
    int band = param_index;
    int base = band * PARAMS_PER_BAND;
    effect_set_param_value(editor->audio_engine, editor->track, editor->effect_slot, base + 2, value);
    sync_from_engine(editor);
    update_curve(editor);
}

// Create band control panel
static GtkWidget* create_band_controls(ProEQEditor *editor, int band) {
    GtkWidget *frame = gtk_frame_new(NULL);

    // Color-coded header
    char css[128];
    snprintf(css, sizeof(css), "frame { border-left: 3px solid rgba(%.0f,%.0f,%.0f,0.8); }",
             band_colors[band][0] * 255, band_colors[band][1] * 255, band_colors[band][2] * 255);

    GtkCssProvider *provider = gtk_css_provider_new();
    gtk_css_provider_load_from_string(provider, css);
    gtk_style_context_add_provider(gtk_widget_get_style_context(frame),
                                   GTK_STYLE_PROVIDER(provider), GTK_STYLE_PROVIDER_PRIORITY_APPLICATION);
    g_object_unref(provider);

    GtkWidget *box = gtk_box_new(GTK_ORIENTATION_VERTICAL, 4);
    gtk_widget_set_margin_start(box, 6);
    gtk_widget_set_margin_end(box, 6);
    gtk_widget_set_margin_top(box, 4);
    gtk_widget_set_margin_bottom(box, 4);

    // Header with enable/solo
    GtkWidget *header = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 4);

    char band_label[8];
    snprintf(band_label, sizeof(band_label), "%d", band + 1);
    GtkWidget *num = gtk_label_new(band_label);
    gtk_widget_set_size_request(num, 16, -1);
    gtk_box_append(GTK_BOX(header), num);

    editor->enable_buttons[band] = gtk_toggle_button_new_with_label("On");
    gtk_widget_set_size_request(editor->enable_buttons[band], 36, -1);
    g_object_set_data(G_OBJECT(editor->enable_buttons[band]), "band", GINT_TO_POINTER(band));
    g_signal_connect(editor->enable_buttons[band], "toggled", G_CALLBACK(on_band_enable_toggled), editor);
    gtk_box_append(GTK_BOX(header), editor->enable_buttons[band]);

    editor->solo_buttons[band] = gtk_toggle_button_new_with_label("S");
    gtk_widget_set_size_request(editor->solo_buttons[band], 28, -1);
    gtk_widget_set_tooltip_text(editor->solo_buttons[band], "Solo");
    g_object_set_data(G_OBJECT(editor->solo_buttons[band]), "band", GINT_TO_POINTER(band));
    g_signal_connect(editor->solo_buttons[band], "toggled", G_CALLBACK(on_band_solo_toggled), editor);
    gtk_box_append(GTK_BOX(header), editor->solo_buttons[band]);

    gtk_box_append(GTK_BOX(box), header);

    // Type dropdown
    editor->type_dropdowns[band] = gtk_drop_down_new_from_strings(filter_type_names);
    gtk_widget_set_size_request(editor->type_dropdowns[band], 80, -1);
    g_object_set_data(G_OBJECT(editor->type_dropdowns[band]), "band", GINT_TO_POINTER(band));
    g_signal_connect(editor->type_dropdowns[band], "notify::selected", G_CALLBACK(on_type_changed), editor);
    gtk_box_append(GTK_BOX(box), editor->type_dropdowns[band]);

    // Frequency knob
    editor->freq_knobs[band] = daw_small_knob_new("Freq", 1000, 20, 20000, "Hz", band, on_freq_changed, editor);
    gtk_box_append(GTK_BOX(box), editor->freq_knobs[band]);

    // Gain knob
    editor->gain_knobs[band] = daw_small_knob_new("Gain", 0, -30, 30, "dB", band, on_gain_changed, editor);
    gtk_box_append(GTK_BOX(box), editor->gain_knobs[band]);

    // Q knob
    editor->q_knobs[band] = daw_small_knob_new("Q", 1.0, 0.1, 30, "", band, on_q_changed, editor);
    gtk_box_append(GTK_BOX(box), editor->q_knobs[band]);

    gtk_frame_set_child(GTK_FRAME(frame), box);
    editor->band_frames[band] = frame;

    return frame;
}

// Create the Pro EQ editor
GtkWidget* pro_eq_editor_new(void *audio_engine, int track, int effect_slot) {
    ProEQEditor *editor = malloc(sizeof(ProEQEditor));
    if (!editor) return NULL;

    memset(editor, 0, sizeof(ProEQEditor));
    editor->audio_engine = audio_engine;
    editor->track = track;
    editor->effect_slot = effect_slot;
    editor->sample_rate = 48000.0f;
    editor->dragging_band = -1;
    editor->hovering_band = -1;

    // Main container
    editor->main_box = gtk_box_new(GTK_ORIENTATION_VERTICAL, 8);
    g_object_set_data_full(G_OBJECT(editor->main_box), "editor", editor, free);

    // Curve display
    editor->curve_area = gtk_drawing_area_new();
    gtk_widget_set_size_request(editor->curve_area, 650, 300);
    gtk_drawing_area_set_draw_func(GTK_DRAWING_AREA(editor->curve_area), draw_curve, editor, NULL);
    gtk_widget_set_hexpand(editor->curve_area, TRUE);
    gtk_widget_set_vexpand(editor->curve_area, TRUE);

    // Add gestures
    GtkGesture *click = gtk_gesture_click_new();
    gtk_gesture_single_set_button(GTK_GESTURE_SINGLE(click), 0); // All buttons
    g_signal_connect(click, "pressed", G_CALLBACK(on_curve_click), editor);
    gtk_widget_add_controller(editor->curve_area, GTK_EVENT_CONTROLLER(click));

    GtkGesture *drag = gtk_gesture_drag_new();
    g_signal_connect(drag, "drag-begin", G_CALLBACK(on_curve_drag_begin), editor);
    g_signal_connect(drag, "drag-update", G_CALLBACK(on_curve_drag_update), editor);
    g_signal_connect(drag, "drag-end", G_CALLBACK(on_curve_drag_end), editor);
    gtk_widget_add_controller(editor->curve_area, GTK_EVENT_CONTROLLER(drag));

    GtkEventController *scroll = gtk_event_controller_scroll_new(GTK_EVENT_CONTROLLER_SCROLL_VERTICAL);
    g_signal_connect(scroll, "scroll", G_CALLBACK(on_curve_scroll), editor);
    gtk_widget_add_controller(editor->curve_area, scroll);

    GtkEventController *motion = gtk_event_controller_motion_new();
    g_signal_connect(motion, "motion", G_CALLBACK(on_curve_motion), editor);
    gtk_widget_add_controller(editor->curve_area, motion);

    gtk_box_append(GTK_BOX(editor->main_box), editor->curve_area);

    // Band controls - horizontal row
    editor->bands_box = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 4);
    gtk_widget_set_halign(editor->bands_box, GTK_ALIGN_CENTER);

    for (int i = 0; i < MAX_BANDS; i++) {
        GtkWidget *band_ctrl = create_band_controls(editor, i);
        gtk_box_append(GTK_BOX(editor->bands_box), band_ctrl);
    }

    // Wrap in scrolled window for small screens
    GtkWidget *scroll_win = gtk_scrolled_window_new();
    gtk_scrolled_window_set_policy(GTK_SCROLLED_WINDOW(scroll_win), GTK_POLICY_AUTOMATIC, GTK_POLICY_NEVER);
    gtk_scrolled_window_set_child(GTK_SCROLLED_WINDOW(scroll_win), editor->bands_box);
    gtk_box_append(GTK_BOX(editor->main_box), scroll_win);

    // Sync from engine and update
    sync_from_engine(editor);

    // Update widget values
    for (int i = 0; i < MAX_BANDS; i++) {
        gtk_toggle_button_set_active(GTK_TOGGLE_BUTTON(editor->enable_buttons[i]), editor->bands[i].enabled);
        gtk_toggle_button_set_active(GTK_TOGGLE_BUTTON(editor->solo_buttons[i]), editor->bands[i].solo);
        gtk_drop_down_set_selected(GTK_DROP_DOWN(editor->type_dropdowns[i]), editor->bands[i].filter_type);
    }

    update_curve(editor);

    return editor->main_box;
}

void pro_eq_editor_refresh(GtkWidget *widget) {
    ProEQEditor *editor = g_object_get_data(G_OBJECT(widget), "editor");
    if (!editor) return;

    sync_from_engine(editor);

    // Update widgets
    for (int i = 0; i < MAX_BANDS; i++) {
        gtk_toggle_button_set_active(GTK_TOGGLE_BUTTON(editor->enable_buttons[i]), editor->bands[i].enabled);
        gtk_toggle_button_set_active(GTK_TOGGLE_BUTTON(editor->solo_buttons[i]), editor->bands[i].solo);
        gtk_drop_down_set_selected(GTK_DROP_DOWN(editor->type_dropdowns[i]), editor->bands[i].filter_type);
    }

    update_curve(editor);
}

void pro_eq_editor_get_preferred_size(int *width, int *height) {
    if (width) *width = 750;
    if (height) *height = 550;
}
