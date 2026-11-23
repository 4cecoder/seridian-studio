/**
 * Effect Modal - Standalone floating window for individual effects
 */

#include "effect_modal_gtk.h"
#include "effects_chain_gtk.h"
#include "parametric_eq_editor.h"
#include "pro_eq_editor.h"
#include "daw_widgets.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define MAX_PARAMS 16

struct EffectModal {
    GtkWidget *window;
    GtkWidget *content_box;
    GtkWidget *params_grid;
    GtkWidget *bypass_check;
    GtkWidget *title_label;

    // Custom editors
    GtkWidget *eq_editor;

    // Parameter widgets
    GtkWidget *param_widgets[MAX_PARAMS];

    void *audio_engine;
    int track;
    int effect_slot;

    // For window positioning
    int window_x;
    int window_y;
};

// Forward declarations
static void update_params(EffectModal *modal);
static void on_param_changed(float value, int param_index, void *user_data);
static void on_bypass_toggled(GtkCheckButton *check, gpointer user_data);
static gboolean on_close_request(GtkWindow *window, gpointer user_data);

// Get title for effect modal
static void get_effect_title(EffectModal *modal, char *buffer, size_t size) {
    const char *effect_name = track_get_effect_name(modal->audio_engine, modal->track, modal->effect_slot);

    if (modal->track < 0) {
        snprintf(buffer, size, "Master: %s", effect_name);
    } else {
        snprintf(buffer, size, "Track %d: %s", modal->track + 1, effect_name);
    }
}

// Parameter change callback
static void on_param_changed(float value, int param_index, void *user_data) {
    EffectModal *modal = (EffectModal *)user_data;
    if (!modal) return;

    effect_set_param_value(modal->audio_engine, modal->track, modal->effect_slot, param_index, value);
}

// Bypass toggle callback
static void on_bypass_toggled(GtkCheckButton *check, gpointer user_data) {
    EffectModal *modal = (EffectModal *)user_data;
    if (!modal) return;

    gboolean active = gtk_check_button_get_active(check);
    track_set_effect_bypass(modal->audio_engine, modal->track, modal->effect_slot, active ? 1 : 0);

    // Update title to show bypass state
    char title[128];
    get_effect_title(modal, title, sizeof(title));
    if (active) {
        strncat(title, " [BYPASSED]", sizeof(title) - strlen(title) - 1);
    }
    gtk_window_set_title(GTK_WINDOW(modal->window), title);
}

// Close request - hide instead of destroy to allow reopening
static gboolean on_close_request(GtkWindow *window, gpointer user_data) {
    (void)user_data;
    gtk_widget_set_visible(GTK_WIDGET(window), FALSE);
    return TRUE;  // Prevent destruction
}

// Update parameter widgets
static void update_params(EffectModal *modal) {
    // Clear existing widgets
    if (modal->params_grid) {
        GtkWidget *child = gtk_widget_get_first_child(modal->params_grid);
        while (child) {
            GtkWidget *next = gtk_widget_get_next_sibling(child);
            gtk_grid_remove(GTK_GRID(modal->params_grid), child);
            child = next;
        }
    }

    // Remove old EQ editor if present
    if (modal->eq_editor) {
        gtk_box_remove(GTK_BOX(modal->content_box), modal->eq_editor);
        modal->eq_editor = NULL;
    }

    // Reset param widgets
    for (int i = 0; i < MAX_PARAMS; i++) {
        modal->param_widgets[i] = NULL;
    }

    // Check effect type
    int effect_type = track_get_effect_type(modal->audio_engine, modal->track, modal->effect_slot);

    // Pro EQ (type 23) gets FabFilter-style visual editor
    if (effect_type == 23) {
        gtk_widget_set_visible(modal->params_grid, FALSE);

        modal->eq_editor = pro_eq_editor_new(modal->audio_engine, modal->track, modal->effect_slot);
        gtk_box_append(GTK_BOX(modal->content_box), modal->eq_editor);

        // Make window larger for Pro EQ
        gtk_window_set_default_size(GTK_WINDOW(modal->window), 800, 600);
        return;
    }

    // Parametric EQ (type 22) gets custom editor
    if (effect_type == 22) {
        gtk_widget_set_visible(modal->params_grid, FALSE);

        modal->eq_editor = parametric_eq_editor_new(modal->audio_engine, modal->track, modal->effect_slot);
        gtk_box_append(GTK_BOX(modal->content_box), modal->eq_editor);

        // Make window larger for EQ
        gtk_window_set_default_size(GTK_WINDOW(modal->window), 700, 550);
        return;
    }

    // Standard parameter grid for other effects
    gtk_widget_set_visible(modal->params_grid, TRUE);

    int param_count = effect_get_param_count(modal->audio_engine, modal->track, modal->effect_slot);

    if (param_count == 0) {
        GtkWidget *label = gtk_label_new("No parameters");
        gtk_widget_set_opacity(label, 0.6);
        gtk_grid_attach(GTK_GRID(modal->params_grid), label, 0, 0, 2, 1);
        return;
    }

    // Create parameter widgets
    // Use a 2-column layout for compact display
    int col = 0;
    int row = 0;

    for (int i = 0; i < param_count && i < MAX_PARAMS; i++) {
        const char *name = effect_get_param_name(modal->audio_engine, modal->track, modal->effect_slot, i);
        float value = effect_get_param_value(modal->audio_engine, modal->track, modal->effect_slot, i);
        float min = effect_get_param_min(modal->audio_engine, modal->track, modal->effect_slot, i);
        float max = effect_get_param_max(modal->audio_engine, modal->track, modal->effect_slot, i);
        const char *unit = effect_get_param_unit(modal->audio_engine, modal->track, modal->effect_slot, i);

        // Choose widget type based on parameter characteristics
        GtkWidget *widget;

        // Use knobs for most parameters, sliders for large ranges
        if (max - min > 1000 || strstr(name, "Time") || strstr(name, "Delay")) {
            // Horizontal slider for large ranges or time-based params
            widget = daw_hslider_new(name, value, min, max, unit, i, on_param_changed, modal);
            gtk_widget_set_hexpand(widget, TRUE);
            gtk_grid_attach(GTK_GRID(modal->params_grid), widget, 0, row, 2, 1);
            row++;
            col = 0;
        } else {
            // Knob for standard params
            widget = daw_small_knob_new(name, value, min, max, unit, i, on_param_changed, modal);
            gtk_grid_attach(GTK_GRID(modal->params_grid), widget, col, row, 1, 1);
            col++;
            if (col >= 4) {  // 4 knobs per row
                col = 0;
                row++;
            }
        }

        modal->param_widgets[i] = widget;
    }

    // Size based on param count
    int width = (param_count <= 4) ? 350 : 450;
    int height = 150 + (row + 1) * 80;
    gtk_window_set_default_size(GTK_WINDOW(modal->window), width, height);
}

// Create effect modal
EffectModal* effect_modal_new(GtkWindow *parent, void *audio_engine, int track, int effect_slot) {
    EffectModal *modal = malloc(sizeof(EffectModal));
    if (!modal) return NULL;

    memset(modal, 0, sizeof(EffectModal));
    modal->audio_engine = audio_engine;
    modal->track = track;
    modal->effect_slot = effect_slot;

    // Create window
    modal->window = gtk_window_new();

    char title[128];
    get_effect_title(modal, title, sizeof(title));
    gtk_window_set_title(GTK_WINDOW(modal->window), title);
    gtk_window_set_default_size(GTK_WINDOW(modal->window), 400, 300);
    gtk_window_set_resizable(GTK_WINDOW(modal->window), TRUE);

    // Not modal - allow multiple windows
    if (parent) {
        gtk_window_set_transient_for(GTK_WINDOW(modal->window), parent);
    }

    // Handle close
    g_signal_connect(modal->window, "close-request", G_CALLBACK(on_close_request), modal);

    // Main container
    GtkWidget *main_box = gtk_box_new(GTK_ORIENTATION_VERTICAL, 8);
    gtk_widget_set_margin_start(main_box, 12);
    gtk_widget_set_margin_end(main_box, 12);
    gtk_widget_set_margin_top(main_box, 12);
    gtk_widget_set_margin_bottom(main_box, 12);

    // Header with effect name and bypass
    GtkWidget *header = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 12);

    // Effect name/title
    const char *effect_name = track_get_effect_name(audio_engine, track, effect_slot);
    char markup[256];
    snprintf(markup, sizeof(markup),
        "<span foreground='" DAW_COLOR_CYAN "' weight='bold' size='large'>%s</span>", effect_name);
    modal->title_label = gtk_label_new(NULL);
    gtk_label_set_markup(GTK_LABEL(modal->title_label), markup);
    gtk_widget_set_hexpand(modal->title_label, TRUE);
    gtk_widget_set_halign(modal->title_label, GTK_ALIGN_START);
    gtk_box_append(GTK_BOX(header), modal->title_label);

    // Bypass checkbox
    int bypassed = track_get_effect_bypassed(audio_engine, track, effect_slot);
    modal->bypass_check = gtk_check_button_new_with_label("Bypass");
    gtk_check_button_set_active(GTK_CHECK_BUTTON(modal->bypass_check), bypassed);
    g_signal_connect(modal->bypass_check, "toggled", G_CALLBACK(on_bypass_toggled), modal);
    gtk_box_append(GTK_BOX(header), modal->bypass_check);

    gtk_box_append(GTK_BOX(main_box), header);

    // Separator
    GtkWidget *sep = gtk_separator_new(GTK_ORIENTATION_HORIZONTAL);
    gtk_widget_set_margin_top(sep, 4);
    gtk_widget_set_margin_bottom(sep, 8);
    gtk_box_append(GTK_BOX(main_box), sep);

    // Content area (scrollable)
    GtkWidget *scroll = gtk_scrolled_window_new();
    gtk_scrolled_window_set_policy(GTK_SCROLLED_WINDOW(scroll), GTK_POLICY_NEVER, GTK_POLICY_AUTOMATIC);
    gtk_widget_set_vexpand(scroll, TRUE);

    modal->content_box = gtk_box_new(GTK_ORIENTATION_VERTICAL, 8);

    // Parameters grid
    modal->params_grid = gtk_grid_new();
    gtk_grid_set_row_spacing(GTK_GRID(modal->params_grid), 12);
    gtk_grid_set_column_spacing(GTK_GRID(modal->params_grid), 16);
    gtk_widget_set_halign(modal->params_grid, GTK_ALIGN_CENTER);
    gtk_box_append(GTK_BOX(modal->content_box), modal->params_grid);

    gtk_scrolled_window_set_child(GTK_SCROLLED_WINDOW(scroll), modal->content_box);
    gtk_box_append(GTK_BOX(main_box), scroll);

    gtk_window_set_child(GTK_WINDOW(modal->window), main_box);

    // Populate parameters
    update_params(modal);

    return modal;
}

void effect_modal_show(EffectModal *modal) {
    if (modal && modal->window) {
        // Refresh params before showing
        int bypassed = track_get_effect_bypassed(modal->audio_engine, modal->track, modal->effect_slot);
        gtk_check_button_set_active(GTK_CHECK_BUTTON(modal->bypass_check), bypassed);

        gtk_window_present(GTK_WINDOW(modal->window));
    }
}

void effect_modal_hide(EffectModal *modal) {
    if (modal && modal->window) {
        gtk_widget_set_visible(modal->window, FALSE);
    }
}

void effect_modal_destroy(EffectModal *modal) {
    if (modal) {
        if (modal->window) {
            gtk_window_destroy(GTK_WINDOW(modal->window));
        }
        free(modal);
    }
}

int effect_modal_matches(EffectModal *modal, int track, int effect_slot) {
    if (!modal) return 0;
    return modal->track == track && modal->effect_slot == effect_slot;
}

void effect_modal_update_slot(EffectModal *modal, int new_slot) {
    if (!modal) return;
    modal->effect_slot = new_slot;

    // Update title
    char title[128];
    get_effect_title(modal, title, sizeof(title));
    gtk_window_set_title(GTK_WINDOW(modal->window), title);

    // Refresh params
    update_params(modal);
}

void effect_modal_refresh(EffectModal *modal) {
    if (!modal) return;

    // Update bypass state
    int bypassed = track_get_effect_bypassed(modal->audio_engine, modal->track, modal->effect_slot);
    gtk_check_button_set_active(GTK_CHECK_BUTTON(modal->bypass_check), bypassed);

    // Update title
    char title[128];
    get_effect_title(modal, title, sizeof(title));
    if (bypassed) {
        strncat(title, " [BYPASSED]", sizeof(title) - strlen(title) - 1);
    }
    gtk_window_set_title(GTK_WINDOW(modal->window), title);

    // Refresh EQ editor if present
    if (modal->eq_editor) {
        int effect_type = track_get_effect_type(modal->audio_engine, modal->track, modal->effect_slot);
        if (effect_type == 23) {
            pro_eq_editor_refresh(modal->eq_editor);
        } else {
            parametric_eq_editor_refresh(modal->eq_editor);
        }
    }
}

GtkWidget* effect_modal_get_window(EffectModal *modal) {
    return modal ? modal->window : NULL;
}
