/**
 * DAW Widgets - Implementation
 */

#include "daw_widgets.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>

// Portable M_PI definition
#ifndef M_PI
#define M_PI 3.14159265358979323846
#endif

// =============================================================================
// Value Formatting
// =============================================================================

void daw_format_value(char *buffer, size_t size, float value, float min, float max, const char *unit) {
    if (unit && strlen(unit) > 0) {
        // Has unit - format based on range
        if (max >= 1000) {
            if (value >= 1000) {
                snprintf(buffer, size, "%.1fk %s", value / 1000.0f, unit);
            } else {
                snprintf(buffer, size, "%.0f %s", value, unit);
            }
        } else if (max >= 10) {
            snprintf(buffer, size, "%.1f %s", value, unit);
        } else {
            snprintf(buffer, size, "%.2f %s", value, unit);
        }
    } else {
        // No unit - assume 0-1 is percentage
        if (max <= 1.0f && min >= 0.0f) {
            snprintf(buffer, size, "%.0f%%", value * 100.0f);
        } else if (max - min > 100) {
            snprintf(buffer, size, "%.0f", value);
        } else {
            snprintf(buffer, size, "%.2f", value);
        }
    }
}

// =============================================================================
// Widget Type Suggestion
// =============================================================================

DawWidgetType daw_suggest_widget_type(const char *param_name, float min, float max) {
    // Volume/Level/Gain -> vertical fader
    if (strstr(param_name, "Volume") || strstr(param_name, "Level") ||
        strstr(param_name, "Gain") || strstr(param_name, "Master")) {
        return DAW_WIDGET_VSLIDER;
    }

    // Frequency, time, or wide-range -> horizontal slider
    if (strstr(param_name, "Cutoff") || strstr(param_name, "Freq") ||
        strstr(param_name, "Rate") || strstr(param_name, "Attack") ||
        strstr(param_name, "Decay") || strstr(param_name, "Release") ||
        strstr(param_name, "Detune") || strstr(param_name, "Time") ||
        strstr(param_name, "Delay") || (max - min) > 100.0f) {
        return DAW_WIDGET_HSLIDER;
    }

    // Everything else -> knob
    return DAW_WIDGET_KNOB;
}

// =============================================================================
// Knob Implementation
// =============================================================================

static void knob_draw(GtkDrawingArea *area, cairo_t *cr, int width, int height, gpointer user_data) {
    (void)area;
    DawKnob *knob = (DawKnob *)user_data;
    if (!knob) return;

    double cx = width / 2.0;
    double cy = height / 2.0;
    double radius = DAW_KNOB_RADIUS;

    // Normalize value to 0-1
    float norm = (knob->value - knob->min) / (knob->max - knob->min);
    if (norm < 0) norm = 0;
    if (norm > 1) norm = 1;

    // Knob sweep: from 7 o'clock (min) to 5 o'clock (max), 270° total
    double min_angle = M_PI * 0.75;   // 135° - bottom left
    double max_angle = M_PI * 2.25;   // 405° - bottom right
    double value_angle = min_angle + norm * (max_angle - min_angle);

    // Background arc (track)
    cairo_set_line_width(cr, DAW_KNOB_LINE_WIDTH + 2);
    cairo_set_source_rgb(cr, DAW_RGB_BG_DARK);
    cairo_arc(cr, cx, cy, radius, min_angle, max_angle);
    cairo_stroke(cr);

    // Value arc
    cairo_set_line_width(cr, DAW_KNOB_LINE_WIDTH);
    cairo_set_source_rgb(cr, DAW_RGB_ACCENT);
    if (norm > 0.01) {
        cairo_arc(cr, cx, cy, radius, min_angle, value_angle);
        cairo_stroke(cr);
    }

    // Knob center
    cairo_set_source_rgb(cr, DAW_RGB_BG_HIGHLIGHT);
    cairo_arc(cr, cx, cy, radius - 6, 0, 2 * M_PI);
    cairo_fill(cr);

    // Pointer line
    cairo_set_source_rgb(cr, DAW_RGB_FG);
    cairo_set_line_width(cr, 2.0);
    double pointer_inner = radius - 10;
    double pointer_outer = radius - 2;
    cairo_move_to(cr, cx + pointer_inner * cos(value_angle), cy + pointer_inner * sin(value_angle));
    cairo_line_to(cr, cx + pointer_outer * cos(value_angle), cy + pointer_outer * sin(value_angle));
    cairo_stroke(cr);
}

static void knob_update_value_label(DawKnob *knob) {
    if (!knob || !knob->value_label) return;

    char val_str[32];
    daw_format_value(val_str, sizeof(val_str), knob->value, knob->min, knob->max, knob->unit);
    gtk_label_set_text(GTK_LABEL(knob->value_label), val_str);
}

static void knob_drag_begin(GtkGestureDrag *gesture, double x, double y, gpointer user_data) {
    (void)gesture;
    (void)x;
    (void)y;
    DawKnob *knob = (DawKnob *)user_data;
    if (!knob) return;

    knob->drag_start_value = knob->value;
    knob->is_dragging = true;
}

static void knob_drag_update(GtkGestureDrag *gesture, double offset_x, double offset_y, gpointer user_data) {
    (void)gesture;
    (void)offset_x;
    DawKnob *knob = (DawKnob *)user_data;
    if (!knob || !knob->is_dragging) return;

    // Vertical drag: up = increase, 100px = full range
    float range = knob->max - knob->min;
    float delta = (float)(-offset_y / 100.0) * range;

    float new_value = knob->drag_start_value + delta;
    if (new_value < knob->min) new_value = knob->min;
    if (new_value > knob->max) new_value = knob->max;

    if (new_value != knob->value) {
        knob->value = new_value;
        knob_update_value_label(knob);
        gtk_widget_queue_draw(knob->drawing_area);

        if (knob->on_change) {
            knob->on_change(new_value, knob->param_index, knob->user_data);
        }
    }
}

static void knob_drag_end(GtkGestureDrag *gesture, double offset_x, double offset_y, gpointer user_data) {
    (void)gesture;
    (void)offset_x;
    (void)offset_y;
    DawKnob *knob = (DawKnob *)user_data;
    if (knob) {
        knob->is_dragging = false;
    }
}

// Double-click to reset
static void knob_click(GtkGestureClick *gesture, int n_press, double x, double y, gpointer user_data) {
    (void)gesture;
    (void)x;
    (void)y;
    DawKnob *knob = (DawKnob *)user_data;
    if (!knob) return;

    if (n_press == 2) {
        // Double-click: reset to default
        knob->value = knob->default_value;
        knob_update_value_label(knob);
        gtk_widget_queue_draw(knob->drawing_area);

        if (knob->on_change) {
            knob->on_change(knob->value, knob->param_index, knob->user_data);
        }
    }
}

GtkWidget* daw_knob_new(const char *name, float value, float min, float max,
                        const char *unit, int param_index,
                        DawValueChangedCallback on_change, void *user_data) {
    DawKnob *knob = g_new0(DawKnob, 1);
    knob->value = value;
    knob->min = min;
    knob->max = max;
    knob->default_value = value;
    knob->param_index = param_index;
    knob->unit = unit;
    knob->on_change = on_change;
    knob->user_data = user_data;

    // Container
    knob->container = gtk_box_new(GTK_ORIENTATION_VERTICAL, 4);
    gtk_widget_set_halign(knob->container, GTK_ALIGN_CENTER);

    // Drawing area
    knob->drawing_area = gtk_drawing_area_new();
    gtk_widget_set_size_request(knob->drawing_area, DAW_KNOB_SIZE, DAW_KNOB_SIZE);
    gtk_drawing_area_set_draw_func(GTK_DRAWING_AREA(knob->drawing_area),
                                   (GtkDrawingAreaDrawFunc)knob_draw, knob, NULL);

    // Drag gesture
    GtkGesture *drag = gtk_gesture_drag_new();
    g_signal_connect(drag, "drag-begin", G_CALLBACK(knob_drag_begin), knob);
    g_signal_connect(drag, "drag-update", G_CALLBACK(knob_drag_update), knob);
    g_signal_connect(drag, "drag-end", G_CALLBACK(knob_drag_end), knob);
    gtk_widget_add_controller(knob->drawing_area, GTK_EVENT_CONTROLLER(drag));

    // Click gesture for double-click reset
    GtkGesture *click = gtk_gesture_click_new();
    g_signal_connect(click, "pressed", G_CALLBACK(knob_click), knob);
    gtk_widget_add_controller(knob->drawing_area, GTK_EVENT_CONTROLLER(click));

    gtk_box_append(GTK_BOX(knob->container), knob->drawing_area);

    // Parameter name label
    knob->label = gtk_label_new(name);
    gtk_widget_add_css_class(knob->label, "dim-label");
    gtk_widget_set_size_request(knob->label, DAW_KNOB_SIZE + 20, -1);
    gtk_label_set_ellipsize(GTK_LABEL(knob->label), PANGO_ELLIPSIZE_END);
    gtk_box_append(GTK_BOX(knob->container), knob->label);

    // Value label
    char val_str[32];
    daw_format_value(val_str, sizeof(val_str), value, min, max, unit);
    knob->value_label = gtk_label_new(val_str);
    gtk_widget_add_css_class(knob->value_label, "caption");
    gtk_box_append(GTK_BOX(knob->container), knob->value_label);

    // Store knob data for retrieval
    g_object_set_data_full(G_OBJECT(knob->container), "daw_knob", knob, g_free);

    return knob->container;
}

float daw_knob_get_value(GtkWidget *knob_container) {
    DawKnob *knob = g_object_get_data(G_OBJECT(knob_container), "daw_knob");
    return knob ? knob->value : 0.0f;
}

void daw_knob_set_value(GtkWidget *knob_container, float value) {
    DawKnob *knob = g_object_get_data(G_OBJECT(knob_container), "daw_knob");
    if (!knob) return;

    if (value < knob->min) value = knob->min;
    if (value > knob->max) value = knob->max;

    knob->value = value;
    knob_update_value_label(knob);
    gtk_widget_queue_draw(knob->drawing_area);
}

void daw_knob_reset(GtkWidget *knob_container) {
    DawKnob *knob = g_object_get_data(G_OBJECT(knob_container), "daw_knob");
    if (knob) {
        daw_knob_set_value(knob_container, knob->default_value);
    }
}

// =============================================================================
// Small Knob Implementation (40x40px)
// =============================================================================

typedef struct {
    GtkWidget *container;
    GtkWidget *drawing_area;
    GtkWidget *label;
    GtkWidget *value_label;

    float value;
    float min;
    float max;
    float default_value;

    int param_index;
    const char *unit;

    DawValueChangedCallback on_change;
    void *user_data;

    float drag_start_value;
    bool is_dragging;
} DawSmallKnob;

static void small_knob_draw(GtkDrawingArea *area, cairo_t *cr, int width, int height, gpointer user_data) {
    (void)area;
    DawSmallKnob *knob = (DawSmallKnob *)user_data;
    if (!knob) return;

    double cx = width / 2.0;
    double cy = height / 2.0;
    double radius = DAW_SMALL_KNOB_RADIUS;

    float norm = (knob->value - knob->min) / (knob->max - knob->min);
    if (norm < 0) norm = 0;
    if (norm > 1) norm = 1;

    double min_angle = M_PI * 0.75;
    double max_angle = M_PI * 2.25;
    double value_angle = min_angle + norm * (max_angle - min_angle);

    // Background arc
    cairo_set_line_width(cr, DAW_SMALL_KNOB_LINE_WIDTH + 1);
    cairo_set_source_rgb(cr, DAW_RGB_BG_DARK);
    cairo_arc(cr, cx, cy, radius, min_angle, max_angle);
    cairo_stroke(cr);

    // Value arc
    cairo_set_line_width(cr, DAW_SMALL_KNOB_LINE_WIDTH);
    cairo_set_source_rgb(cr, DAW_RGB_ACCENT);
    if (norm > 0.01) {
        cairo_arc(cr, cx, cy, radius, min_angle, value_angle);
        cairo_stroke(cr);
    }

    // Knob center
    cairo_set_source_rgb(cr, DAW_RGB_BG_HIGHLIGHT);
    cairo_arc(cr, cx, cy, radius - 4, 0, 2 * M_PI);
    cairo_fill(cr);

    // Pointer line
    cairo_set_source_rgb(cr, DAW_RGB_FG);
    cairo_set_line_width(cr, 1.5);
    double pointer_inner = radius - 7;
    double pointer_outer = radius - 1;
    cairo_move_to(cr, cx + pointer_inner * cos(value_angle), cy + pointer_inner * sin(value_angle));
    cairo_line_to(cr, cx + pointer_outer * cos(value_angle), cy + pointer_outer * sin(value_angle));
    cairo_stroke(cr);
}

static void small_knob_update_value_label(DawSmallKnob *knob) {
    if (!knob || !knob->value_label) return;
    char val_str[32];
    daw_format_value(val_str, sizeof(val_str), knob->value, knob->min, knob->max, knob->unit);
    gtk_label_set_text(GTK_LABEL(knob->value_label), val_str);
}

static void small_knob_drag_begin(GtkGestureDrag *gesture, double x, double y, gpointer user_data) {
    (void)gesture; (void)x; (void)y;
    DawSmallKnob *knob = (DawSmallKnob *)user_data;
    if (!knob) return;
    knob->drag_start_value = knob->value;
    knob->is_dragging = true;
}

static void small_knob_drag_update(GtkGestureDrag *gesture, double offset_x, double offset_y, gpointer user_data) {
    (void)gesture; (void)offset_x;
    DawSmallKnob *knob = (DawSmallKnob *)user_data;
    if (!knob || !knob->is_dragging) return;

    float range = knob->max - knob->min;
    float delta = (float)(-offset_y / 80.0) * range;  // Slightly faster response for small knobs

    float new_value = knob->drag_start_value + delta;
    if (new_value < knob->min) new_value = knob->min;
    if (new_value > knob->max) new_value = knob->max;

    if (new_value != knob->value) {
        knob->value = new_value;
        small_knob_update_value_label(knob);
        gtk_widget_queue_draw(knob->drawing_area);
        if (knob->on_change) {
            knob->on_change(new_value, knob->param_index, knob->user_data);
        }
    }
}

static void small_knob_drag_end(GtkGestureDrag *gesture, double offset_x, double offset_y, gpointer user_data) {
    (void)gesture; (void)offset_x; (void)offset_y;
    DawSmallKnob *knob = (DawSmallKnob *)user_data;
    if (knob) knob->is_dragging = false;
}

static void small_knob_click(GtkGestureClick *gesture, int n_press, double x, double y, gpointer user_data) {
    (void)gesture; (void)x; (void)y;
    DawSmallKnob *knob = (DawSmallKnob *)user_data;
    if (!knob) return;

    if (n_press == 2) {
        knob->value = knob->default_value;
        small_knob_update_value_label(knob);
        gtk_widget_queue_draw(knob->drawing_area);
        if (knob->on_change) {
            knob->on_change(knob->value, knob->param_index, knob->user_data);
        }
    }
}

GtkWidget* daw_small_knob_new(const char *name, float value, float min, float max,
                               const char *unit, int param_index,
                               DawValueChangedCallback on_change, void *user_data) {
    DawSmallKnob *knob = g_new0(DawSmallKnob, 1);
    knob->value = value;
    knob->min = min;
    knob->max = max;
    knob->default_value = value;
    knob->param_index = param_index;
    knob->unit = unit;
    knob->on_change = on_change;
    knob->user_data = user_data;

    // Container
    knob->container = gtk_box_new(GTK_ORIENTATION_VERTICAL, 2);
    gtk_widget_set_halign(knob->container, GTK_ALIGN_CENTER);

    // Drawing area
    knob->drawing_area = gtk_drawing_area_new();
    gtk_widget_set_size_request(knob->drawing_area, DAW_SMALL_KNOB_SIZE, DAW_SMALL_KNOB_SIZE);
    gtk_drawing_area_set_draw_func(GTK_DRAWING_AREA(knob->drawing_area),
                                   (GtkDrawingAreaDrawFunc)small_knob_draw, knob, NULL);

    // Drag gesture
    GtkGesture *drag = gtk_gesture_drag_new();
    g_signal_connect(drag, "drag-begin", G_CALLBACK(small_knob_drag_begin), knob);
    g_signal_connect(drag, "drag-update", G_CALLBACK(small_knob_drag_update), knob);
    g_signal_connect(drag, "drag-end", G_CALLBACK(small_knob_drag_end), knob);
    gtk_widget_add_controller(knob->drawing_area, GTK_EVENT_CONTROLLER(drag));

    // Click gesture for double-click reset
    GtkGesture *click = gtk_gesture_click_new();
    g_signal_connect(click, "pressed", G_CALLBACK(small_knob_click), knob);
    gtk_widget_add_controller(knob->drawing_area, GTK_EVENT_CONTROLLER(click));

    gtk_box_append(GTK_BOX(knob->container), knob->drawing_area);

    // Parameter name label (smaller font)
    knob->label = gtk_label_new(name);
    gtk_widget_add_css_class(knob->label, "dim-label");
    gtk_widget_add_css_class(knob->label, "caption");
    gtk_widget_set_size_request(knob->label, DAW_SMALL_KNOB_SIZE + 10, -1);
    gtk_label_set_ellipsize(GTK_LABEL(knob->label), PANGO_ELLIPSIZE_END);
    gtk_box_append(GTK_BOX(knob->container), knob->label);

    // Value label (smaller)
    char val_str[32];
    daw_format_value(val_str, sizeof(val_str), value, min, max, unit);
    knob->value_label = gtk_label_new(val_str);
    gtk_widget_add_css_class(knob->value_label, "caption");
    gtk_widget_set_opacity(knob->value_label, 0.7);
    gtk_box_append(GTK_BOX(knob->container), knob->value_label);

    g_object_set_data_full(G_OBJECT(knob->container), "daw_small_knob", knob, g_free);

    return knob->container;
}

// =============================================================================
// Vertical Slider Implementation
// =============================================================================

static void vslider_value_changed(GtkRange *range, gpointer user_data) {
    DawVSlider *slider = (DawVSlider *)user_data;
    if (!slider) return;

    float value = (float)gtk_range_get_value(range);

    // Update value label
    if (slider->value_label) {
        char val_str[32];
        daw_format_value(val_str, sizeof(val_str), value, slider->min, slider->max, slider->unit);
        gtk_label_set_text(GTK_LABEL(slider->value_label), val_str);
    }

    if (slider->on_change) {
        slider->on_change(value, slider->param_index, slider->user_data);
    }
}

GtkWidget* daw_vslider_new(const char *name, float value, float min, float max,
                           const char *unit, int param_index,
                           DawValueChangedCallback on_change, void *user_data) {
    DawVSlider *slider = g_new0(DawVSlider, 1);
    slider->min = min;
    slider->max = max;
    slider->param_index = param_index;
    slider->unit = unit;
    slider->on_change = on_change;
    slider->user_data = user_data;

    // Container
    slider->container = gtk_box_new(GTK_ORIENTATION_VERTICAL, 4);
    gtk_widget_set_halign(slider->container, GTK_ALIGN_CENTER);

    // Vertical slider
    slider->slider = gtk_scale_new_with_range(GTK_ORIENTATION_VERTICAL, min, max, (max - min) / 100.0);
    gtk_range_set_value(GTK_RANGE(slider->slider), value);
    gtk_range_set_inverted(GTK_RANGE(slider->slider), TRUE);  // Up = higher
    gtk_widget_set_size_request(slider->slider, DAW_VSLIDER_WIDTH, DAW_VSLIDER_HEIGHT);
    gtk_scale_set_draw_value(GTK_SCALE(slider->slider), FALSE);

    g_signal_connect(slider->slider, "value-changed", G_CALLBACK(vslider_value_changed), slider);

    gtk_box_append(GTK_BOX(slider->container), slider->slider);

    // Label
    slider->label = gtk_label_new(name);
    gtk_widget_add_css_class(slider->label, "dim-label");
    gtk_box_append(GTK_BOX(slider->container), slider->label);

    // Value label
    char val_str[32];
    daw_format_value(val_str, sizeof(val_str), value, min, max, unit);
    slider->value_label = gtk_label_new(val_str);
    gtk_widget_add_css_class(slider->value_label, "caption");
    gtk_box_append(GTK_BOX(slider->container), slider->value_label);

    g_object_set_data_full(G_OBJECT(slider->container), "daw_vslider", slider, g_free);

    return slider->container;
}

float daw_vslider_get_value(GtkWidget *slider_container) {
    DawVSlider *slider = g_object_get_data(G_OBJECT(slider_container), "daw_vslider");
    return slider ? (float)gtk_range_get_value(GTK_RANGE(slider->slider)) : 0.0f;
}

void daw_vslider_set_value(GtkWidget *slider_container, float value) {
    DawVSlider *slider = g_object_get_data(G_OBJECT(slider_container), "daw_vslider");
    if (slider) {
        gtk_range_set_value(GTK_RANGE(slider->slider), value);
    }
}

// =============================================================================
// Horizontal Slider Implementation
// =============================================================================

static void hslider_value_changed(GtkRange *range, gpointer user_data) {
    DawHSlider *slider = (DawHSlider *)user_data;
    if (!slider) return;

    float value = (float)gtk_range_get_value(range);

    // Update value label
    if (slider->value_label) {
        char val_str[32];
        daw_format_value(val_str, sizeof(val_str), value, slider->min, slider->max, slider->unit);
        gtk_label_set_text(GTK_LABEL(slider->value_label), val_str);
    }

    if (slider->on_change) {
        slider->on_change(value, slider->param_index, slider->user_data);
    }
}

GtkWidget* daw_hslider_new(const char *name, float value, float min, float max,
                           const char *unit, int param_index,
                           DawValueChangedCallback on_change, void *user_data) {
    DawHSlider *slider = g_new0(DawHSlider, 1);
    slider->min = min;
    slider->max = max;
    slider->param_index = param_index;
    slider->unit = unit;
    slider->on_change = on_change;
    slider->user_data = user_data;

    // Container
    slider->container = gtk_box_new(GTK_ORIENTATION_VERTICAL, 2);

    // Label row
    GtkWidget *label_box = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8);
    slider->label = gtk_label_new(name);
    gtk_widget_set_halign(slider->label, GTK_ALIGN_START);
    gtk_widget_set_hexpand(slider->label, TRUE);
    gtk_box_append(GTK_BOX(label_box), slider->label);

    // Value label
    char val_str[32];
    daw_format_value(val_str, sizeof(val_str), value, min, max, unit);
    slider->value_label = gtk_label_new(val_str);
    gtk_widget_add_css_class(slider->value_label, "dim-label");
    gtk_box_append(GTK_BOX(label_box), slider->value_label);

    gtk_box_append(GTK_BOX(slider->container), label_box);

    // Horizontal slider
    slider->slider = gtk_scale_new_with_range(GTK_ORIENTATION_HORIZONTAL, min, max, (max - min) / 100.0);
    gtk_range_set_value(GTK_RANGE(slider->slider), value);
    gtk_widget_set_size_request(slider->slider, DAW_HSLIDER_WIDTH, -1);
    gtk_widget_set_hexpand(slider->slider, TRUE);
    gtk_scale_set_draw_value(GTK_SCALE(slider->slider), FALSE);

    g_signal_connect(slider->slider, "value-changed", G_CALLBACK(hslider_value_changed), slider);

    gtk_box_append(GTK_BOX(slider->container), slider->slider);

    g_object_set_data_full(G_OBJECT(slider->container), "daw_hslider", slider, g_free);

    return slider->container;
}

float daw_hslider_get_value(GtkWidget *slider_container) {
    DawHSlider *slider = g_object_get_data(G_OBJECT(slider_container), "daw_hslider");
    return slider ? (float)gtk_range_get_value(GTK_RANGE(slider->slider)) : 0.0f;
}

void daw_hslider_set_value(GtkWidget *slider_container, float value) {
    DawHSlider *slider = g_object_get_data(G_OBJECT(slider_container), "daw_hslider");
    if (slider) {
        gtk_range_set_value(GTK_RANGE(slider->slider), value);
    }
}

// =============================================================================
// Auto Widget Creation
// =============================================================================

GtkWidget* daw_param_widget_new(const char *name, float value, float min, float max,
                                const char *unit, int param_index,
                                DawValueChangedCallback on_change, void *user_data) {
    DawWidgetType type = daw_suggest_widget_type(name, min, max);

    switch (type) {
        case DAW_WIDGET_VSLIDER:
            return daw_vslider_new(name, value, min, max, unit, param_index, on_change, user_data);
        case DAW_WIDGET_HSLIDER:
            return daw_hslider_new(name, value, min, max, unit, param_index, on_change, user_data);
        case DAW_WIDGET_KNOB:
        default:
            return daw_knob_new(name, value, min, max, unit, param_index, on_change, user_data);
    }
}

// =============================================================================
// Layout Helpers
// =============================================================================

void daw_set_margins(GtkWidget *widget, int start, int end, int top, int bottom) {
    gtk_widget_set_margin_start(widget, start);
    gtk_widget_set_margin_end(widget, end);
    gtk_widget_set_margin_top(widget, top);
    gtk_widget_set_margin_bottom(widget, bottom);
}

void daw_set_margin(GtkWidget *widget, int margin) {
    daw_set_margins(widget, margin, margin, margin, margin);
}

void daw_set_margins_h(GtkWidget *widget, int margin) {
    gtk_widget_set_margin_start(widget, margin);
    gtk_widget_set_margin_end(widget, margin);
}

void daw_set_margins_v(GtkWidget *widget, int margin) {
    gtk_widget_set_margin_top(widget, margin);
    gtk_widget_set_margin_bottom(widget, margin);
}

// =============================================================================
// Section & Separator Builders
// =============================================================================

GtkWidget* daw_section_header(const char *title) {
    GtkWidget *label = gtk_label_new(NULL);
    char markup[256];
    snprintf(markup, sizeof(markup), "<span weight='bold'>%s</span>", title);
    gtk_label_set_markup(GTK_LABEL(label), markup);
    gtk_widget_set_halign(label, GTK_ALIGN_START);
    gtk_widget_set_margin_bottom(label, 8);
    return label;
}

GtkWidget* daw_separator(int margin_v) {
    GtkWidget *sep = gtk_separator_new(GTK_ORIENTATION_HORIZONTAL);
    daw_set_margins_v(sep, margin_v);
    return sep;
}

GtkWidget* daw_frame_new(const char *title, GtkWidget **out_frame) {
    GtkWidget *frame = gtk_frame_new(title);
    GtkWidget *content = gtk_box_new(GTK_ORIENTATION_VERTICAL, 8);
    daw_set_margin(content, 12);
    gtk_frame_set_child(GTK_FRAME(frame), content);

    if (out_frame) {
        *out_frame = frame;
    }

    return content;
}

// =============================================================================
// Labeled Control Factories
// =============================================================================

// Standard label width for alignment
#define LABEL_WIDTH 150

GtkWidget* daw_labeled_dropdown(const char *label_text, const char **items,
                                 int selected, GtkWidget **out_dropdown) {
    GtkWidget *box = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 12);
    daw_set_margins_v(box, 8);

    // Label
    GtkWidget *label = gtk_label_new(label_text);
    gtk_widget_set_size_request(label, LABEL_WIDTH, -1);
    gtk_widget_set_halign(label, GTK_ALIGN_START);
    gtk_box_append(GTK_BOX(box), label);

    // Dropdown
    GtkWidget *dropdown = gtk_drop_down_new_from_strings(items);
    gtk_drop_down_set_selected(GTK_DROP_DOWN(dropdown), selected);
    gtk_widget_set_hexpand(dropdown, TRUE);
    gtk_box_append(GTK_BOX(box), dropdown);

    if (out_dropdown) {
        *out_dropdown = dropdown;
    }

    return box;
}

GtkWidget* daw_labeled_switch(const char *label_text, gboolean active,
                               GtkWidget **out_switch) {
    GtkWidget *box = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 12);
    daw_set_margins_v(box, 8);

    // Label
    GtkWidget *label = gtk_label_new(label_text);
    gtk_widget_set_size_request(label, LABEL_WIDTH, -1);
    gtk_widget_set_halign(label, GTK_ALIGN_START);
    gtk_widget_set_hexpand(label, TRUE);
    gtk_box_append(GTK_BOX(box), label);

    // Switch
    GtkWidget *sw = gtk_switch_new();
    gtk_switch_set_active(GTK_SWITCH(sw), active);
    gtk_widget_set_halign(sw, GTK_ALIGN_END);
    gtk_box_append(GTK_BOX(box), sw);

    if (out_switch) {
        *out_switch = sw;
    }

    return box;
}

GtkWidget* daw_labeled_spinner(const char *label_text, double value,
                                double min, double max, double step,
                                GtkWidget **out_spinner) {
    GtkWidget *box = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 12);
    daw_set_margins_v(box, 8);

    // Label
    GtkWidget *label = gtk_label_new(label_text);
    gtk_widget_set_size_request(label, LABEL_WIDTH, -1);
    gtk_widget_set_halign(label, GTK_ALIGN_START);
    gtk_box_append(GTK_BOX(box), label);

    // Spin button
    GtkWidget *spinner = gtk_spin_button_new_with_range(min, max, step);
    gtk_spin_button_set_value(GTK_SPIN_BUTTON(spinner), value);
    gtk_widget_set_hexpand(spinner, TRUE);
    gtk_box_append(GTK_BOX(box), spinner);

    if (out_spinner) {
        *out_spinner = spinner;
    }

    return box;
}

GtkWidget* daw_info_row(const char *label_text, const char *value_text) {
    GtkWidget *box = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 12);
    daw_set_margins_v(box, 4);

    // Label
    GtkWidget *label = gtk_label_new(label_text);
    gtk_widget_set_size_request(label, 180, -1);
    gtk_widget_set_halign(label, GTK_ALIGN_START);
    gtk_box_append(GTK_BOX(box), label);

    // Value with accent color
    GtkWidget *value = gtk_label_new(NULL);
    char markup[256];
    snprintf(markup, sizeof(markup), "<span foreground='" DAW_COLOR_CYAN "'>%s</span>", value_text);
    gtk_label_set_markup(GTK_LABEL(value), markup);
    gtk_widget_set_halign(value, GTK_ALIGN_START);
    gtk_box_append(GTK_BOX(box), value);

    return box;
}

// =============================================================================
// Modal Helpers
// =============================================================================

gboolean daw_modal_close_handler(GtkWindow *window, gpointer user_data) {
    (void)user_data;
    // Hide window instead of destroying
    gtk_widget_set_visible(GTK_WIDGET(window), FALSE);
    return TRUE;  // Prevent default destroy behavior
}

GtkWidget* daw_modal_new(GtkWindow *parent, const char *title,
                          int width, int height, gboolean resizable) {
    GtkWidget *window = gtk_window_new();
    gtk_window_set_title(GTK_WINDOW(window), title);
    gtk_window_set_default_size(GTK_WINDOW(window), width, height);
    gtk_window_set_resizable(GTK_WINDOW(window), resizable);
    // Note: Not using gtk_window_set_modal(TRUE) as it blocks dropdown popovers on macOS

    if (parent) {
        gtk_window_set_transient_for(GTK_WINDOW(window), parent);
    }

    // Connect close handler to hide instead of destroy
    g_signal_connect(window, "close-request", G_CALLBACK(daw_modal_close_handler), NULL);

    return window;
}

GtkWidget* daw_modal_header(const char *title_markup) {
    GtkWidget *header = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 12);
    daw_set_margins(header, 16, 16, 12, 12);

    GtkWidget *title = gtk_label_new(NULL);
    gtk_label_set_markup(GTK_LABEL(title), title_markup);
    gtk_widget_set_hexpand(title, TRUE);
    gtk_widget_set_halign(title, GTK_ALIGN_START);
    gtk_box_append(GTK_BOX(header), title);

    return header;
}

// =============================================================================
// Button Factories
// =============================================================================

GtkWidget* daw_icon_button(const char *icon_text, const char *tooltip, int size) {
    GtkWidget *button = gtk_button_new_with_label(icon_text);
    if (size > 0) {
        gtk_widget_set_size_request(button, size, -1);
    }
    if (tooltip) {
        gtk_widget_set_tooltip_text(button, tooltip);
    }
    return button;
}

GtkWidget* daw_destructive_button(const char *icon_text, const char *tooltip, int size) {
    GtkWidget *button = daw_icon_button(icon_text, tooltip, size);
    gtk_widget_add_css_class(button, "destructive-action");
    return button;
}

// =============================================================================
// Transport Button Implementation
// =============================================================================

GtkWidget* daw_transport_button(const char *icon, const char *tooltip, const char *color) {
    GtkWidget *button = gtk_button_new();

    // Create label with large font for the icon
    GtkWidget *label = gtk_label_new(NULL);

    // Build markup with color and larger font
    char markup[256];
    if (color) {
        snprintf(markup, sizeof(markup),
            "<span font_size='x-large' foreground='%s'>%s</span>", color, icon);
    } else {
        snprintf(markup, sizeof(markup),
            "<span font_size='x-large'>%s</span>", icon);
    }
    gtk_label_set_markup(GTK_LABEL(label), markup);

    gtk_button_set_child(GTK_BUTTON(button), label);

    if (tooltip) {
        gtk_widget_set_tooltip_text(button, tooltip);
    }

    // Apply flat style - no borders, no background
    gtk_widget_add_css_class(button, "flat");

    // Minimal padding
    gtk_widget_set_margin_start(button, 2);
    gtk_widget_set_margin_end(button, 2);

    return button;
}

void daw_transport_button_set_icon(GtkWidget *button, const char *icon, const char *color) {
    GtkWidget *label = gtk_button_get_child(GTK_BUTTON(button));
    if (!label || !GTK_IS_LABEL(label)) return;

    char markup[256];
    if (color) {
        snprintf(markup, sizeof(markup),
            "<span font_size='x-large' foreground='%s'>%s</span>", color, icon);
    } else {
        snprintf(markup, sizeof(markup),
            "<span font_size='x-large'>%s</span>", icon);
    }
    gtk_label_set_markup(GTK_LABEL(label), markup);
}

// =============================================================================
// Session Menu Implementation
// =============================================================================

// Internal data for session menu
typedef struct {
    DawSessionMenuCallbacks callbacks;
    GtkWidget *popover;
} SessionMenuData;

// Menu item with optional icon, label, and shortcut
static GtkWidget* create_menu_item(const char *icon, const char *label,
                                    const char *shortcut, GCallback callback,
                                    void *user_data) {
    GtkWidget *button = gtk_button_new();
    gtk_widget_add_css_class(button, "flat");

    GtkWidget *box = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8);
    gtk_widget_set_margin_start(box, 12);
    gtk_widget_set_margin_end(box, 12);
    gtk_widget_set_margin_top(box, 6);
    gtk_widget_set_margin_bottom(box, 6);

    // Icon (optional)
    if (icon) {
        GtkWidget *icon_label = gtk_label_new(icon);
        gtk_widget_set_size_request(icon_label, 16, -1);
        gtk_box_append(GTK_BOX(box), icon_label);
    }

    // Label
    GtkWidget *text_label = gtk_label_new(label);
    gtk_widget_set_hexpand(text_label, TRUE);
    gtk_widget_set_halign(text_label, GTK_ALIGN_START);
    gtk_box_append(GTK_BOX(box), text_label);

    // Shortcut (dimmed)
    if (shortcut) {
        GtkWidget *shortcut_label = gtk_label_new(NULL);
        char shortcut_markup[128];
        snprintf(shortcut_markup, sizeof(shortcut_markup),
            "<span foreground='" DAW_COLOR_COMMENT "' size='small'>%s</span>", shortcut);
        gtk_label_set_markup(GTK_LABEL(shortcut_label), shortcut_markup);
        gtk_box_append(GTK_BOX(box), shortcut_label);
    }

    gtk_button_set_child(GTK_BUTTON(button), box);

    if (callback) {
        g_signal_connect(button, "clicked", callback, user_data);
    }

    return button;
}

// Separator for menu
static GtkWidget* create_menu_separator(void) {
    GtkWidget *sep = gtk_separator_new(GTK_ORIENTATION_HORIZONTAL);
    gtk_widget_set_margin_top(sep, 4);
    gtk_widget_set_margin_bottom(sep, 4);
    gtk_widget_set_margin_start(sep, 8);
    gtk_widget_set_margin_end(sep, 8);
    return sep;
}

// Callback wrappers that close the popover
static void on_menu_new(GtkButton *btn, gpointer user_data) {
    (void)btn;
    SessionMenuData *data = (SessionMenuData *)user_data;
    gtk_popover_popdown(GTK_POPOVER(data->popover));
    if (data->callbacks.on_new)
        data->callbacks.on_new(data->callbacks.user_data);
}

static void on_menu_open(GtkButton *btn, gpointer user_data) {
    (void)btn;
    SessionMenuData *data = (SessionMenuData *)user_data;
    gtk_popover_popdown(GTK_POPOVER(data->popover));
    if (data->callbacks.on_open)
        data->callbacks.on_open(data->callbacks.user_data);
}

static void on_menu_save(GtkButton *btn, gpointer user_data) {
    (void)btn;
    SessionMenuData *data = (SessionMenuData *)user_data;
    gtk_popover_popdown(GTK_POPOVER(data->popover));
    if (data->callbacks.on_save)
        data->callbacks.on_save(data->callbacks.user_data);
}

static void on_menu_save_as(GtkButton *btn, gpointer user_data) {
    (void)btn;
    SessionMenuData *data = (SessionMenuData *)user_data;
    gtk_popover_popdown(GTK_POPOVER(data->popover));
    if (data->callbacks.on_save_as)
        data->callbacks.on_save_as(data->callbacks.user_data);
}

static void on_menu_export_audio(GtkButton *btn, gpointer user_data) {
    (void)btn;
    SessionMenuData *data = (SessionMenuData *)user_data;
    gtk_popover_popdown(GTK_POPOVER(data->popover));
    if (data->callbacks.on_export_audio)
        data->callbacks.on_export_audio(data->callbacks.user_data);
}

static void on_menu_export_midi(GtkButton *btn, gpointer user_data) {
    (void)btn;
    SessionMenuData *data = (SessionMenuData *)user_data;
    gtk_popover_popdown(GTK_POPOVER(data->popover));
    if (data->callbacks.on_export_midi)
        data->callbacks.on_export_midi(data->callbacks.user_data);
}

static void on_menu_import(GtkButton *btn, gpointer user_data) {
    (void)btn;
    SessionMenuData *data = (SessionMenuData *)user_data;
    gtk_popover_popdown(GTK_POPOVER(data->popover));
    if (data->callbacks.on_import)
        data->callbacks.on_import(data->callbacks.user_data);
}

GtkWidget* daw_session_menu_new(DawSessionMenuCallbacks *callbacks) {
    // Allocate data
    SessionMenuData *data = malloc(sizeof(SessionMenuData));
    memset(data, 0, sizeof(SessionMenuData));
    if (callbacks) {
        data->callbacks = *callbacks;
    }

    // Create menu button
    GtkWidget *menu_button = gtk_menu_button_new();

    // Simple text label with chevron
    GtkWidget *btn_box = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 4);
    GtkWidget *text_label = gtk_label_new("Session");
    gtk_box_append(GTK_BOX(btn_box), text_label);

    GtkWidget *chevron = gtk_label_new(NULL);
    gtk_label_set_markup(GTK_LABEL(chevron),
        "<span foreground='" DAW_COLOR_COMMENT "'>▾</span>");
    gtk_box_append(GTK_BOX(btn_box), chevron);

    gtk_menu_button_set_child(GTK_MENU_BUTTON(menu_button), btn_box);
    gtk_menu_button_set_has_frame(GTK_MENU_BUTTON(menu_button), FALSE);
    gtk_widget_add_css_class(menu_button, "flat");
    gtk_widget_set_tooltip_text(menu_button, "Session menu");

    // Create popover with autohide enabled
    GtkWidget *popover = gtk_popover_new();
    data->popover = popover;
    gtk_popover_set_autohide(GTK_POPOVER(popover), TRUE);

    // Popover content
    GtkWidget *content = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0);
    gtk_widget_set_size_request(content, 200, -1);

    // Project section
    gtk_box_append(GTK_BOX(content),
        create_menu_item(NULL, "New Project", "Ctrl+N", G_CALLBACK(on_menu_new), data));
    gtk_box_append(GTK_BOX(content),
        create_menu_item(NULL, "Open...", "Ctrl+O", G_CALLBACK(on_menu_open), data));
    gtk_box_append(GTK_BOX(content),
        create_menu_item(NULL, "Import Audio...", NULL, G_CALLBACK(on_menu_import), data));

    gtk_box_append(GTK_BOX(content), create_menu_separator());

    // Save section
    gtk_box_append(GTK_BOX(content),
        create_menu_item(NULL, "Save", "Ctrl+S", G_CALLBACK(on_menu_save), data));
    gtk_box_append(GTK_BOX(content),
        create_menu_item(NULL, "Save As...", "Ctrl+Shift+S", G_CALLBACK(on_menu_save_as), data));

    gtk_box_append(GTK_BOX(content), create_menu_separator());

    // Export section
    gtk_box_append(GTK_BOX(content),
        create_menu_item(NULL, "Export Audio...", "Ctrl+E", G_CALLBACK(on_menu_export_audio), data));
    gtk_box_append(GTK_BOX(content),
        create_menu_item(NULL, "Export MIDI...", NULL, G_CALLBACK(on_menu_export_midi), data));

    // Bottom padding
    GtkWidget *bottom_pad = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0);
    gtk_widget_set_size_request(bottom_pad, -1, 4);
    gtk_box_append(GTK_BOX(content), bottom_pad);

    gtk_popover_set_child(GTK_POPOVER(popover), content);
    gtk_menu_button_set_popover(GTK_MENU_BUTTON(menu_button), popover);

    // Store data for cleanup
    g_object_set_data_full(G_OBJECT(menu_button), "session-data", data, free);

    return menu_button;
}

void daw_session_menu_set_recent(GtkWidget *menu_button, const char **paths, int count) {
    // TODO: Implement recent files submenu
    (void)menu_button;
    (void)paths;
    (void)count;
}
