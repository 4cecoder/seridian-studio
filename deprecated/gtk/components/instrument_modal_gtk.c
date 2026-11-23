#include "instrument_modal_gtk.h"
#include "daw_widgets.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

// Use colors from daw_widgets.h
#define TOKYONIGHT_CYAN DAW_COLOR_CYAN

// Modal size constants
#define MODAL_WIDTH 850
#define MODAL_HEIGHT 550

// Piano keyboard constants
#define PIANO_START_NOTE 36  // C2
#define PIANO_END_NOTE 96    // C7
#define WHITE_KEY_WIDTH 24
#define WHITE_KEY_HEIGHT 120
#define BLACK_KEY_WIDTH 14
#define BLACK_KEY_HEIGHT 75

// RGB colors for Cairo
typedef struct { double r, g, b; } RGBColor;

static const RGBColor COLOR_WHITE_KEY = {0.95, 0.95, 0.95};
static const RGBColor COLOR_WHITE_KEY_PRESSED = {0.7, 0.85, 1.0};
static const RGBColor COLOR_BLACK_KEY = {0.15, 0.15, 0.18};
static const RGBColor COLOR_BLACK_KEY_PRESSED = {0.3, 0.45, 0.6};
static const RGBColor COLOR_KEY_BORDER = {0.4, 0.4, 0.45};
static const RGBColor COLOR_BLUE = {0x7a/255.0, 0xa2/255.0, 0xf7/255.0};

// Scale lock colors - dim out-of-scale keys, highlight in-scale
static const RGBColor COLOR_WHITE_KEY_OUT_OF_SCALE = {0.6, 0.6, 0.65};
static const RGBColor COLOR_BLACK_KEY_OUT_OF_SCALE = {0.08, 0.08, 0.10};
static const RGBColor COLOR_ROOT_KEY = {0.4, 0.7, 0.4};  // Green tint for root note

struct InstrumentModal {
    GtkWidget *window;
    GtkWidget *piano_area;
    GtkWidget *instrument_dropdown;
    GtkWidget *instrument_name_label;
    GtkWidget *params_box;
    GtkWidget *param_sliders[16];  // Max 16 parameters
    GtkWidget *param_labels[16];

    // Scale lock UI
    GtkWidget *scale_lock_switch;
    GtkWidget *scale_dropdown;
    GtkWidget *root_dropdown;

    void *audio_engine;
    int track;

    // Piano state
    bool keys_pressed[128];  // MIDI note pressed state
    int hover_note;          // Note under mouse cursor

    // Scale lock state
    bool scale_lock_enabled;
    int scale_type;          // 0=chromatic, 1=major, 2=minor, etc.
    int root_note;           // 0-11 (C=0, C#=1, ..., B=11)
};

// QWERTY to MIDI note mapping (two octaves)
// Bottom row: Z-M = C3-B3 (white keys), S,D,G,H,J = black keys
// Top row: Q-P = C4-B4 (white keys), 2,3,5,6,7 = black keys
static int qwerty_to_note(guint keyval) {
    // Lower octave (C3 = 48)
    switch (keyval) {
        case GDK_KEY_z: case GDK_KEY_Z: return 48;  // C3
        case GDK_KEY_s: case GDK_KEY_S: return 49;  // C#3
        case GDK_KEY_x: case GDK_KEY_X: return 50;  // D3
        case GDK_KEY_d: case GDK_KEY_D: return 51;  // D#3
        case GDK_KEY_c: case GDK_KEY_C: return 52;  // E3
        case GDK_KEY_v: case GDK_KEY_V: return 53;  // F3
        case GDK_KEY_g: case GDK_KEY_G: return 54;  // F#3
        case GDK_KEY_b: case GDK_KEY_B: return 55;  // G3
        case GDK_KEY_h: case GDK_KEY_H: return 56;  // G#3
        case GDK_KEY_n: case GDK_KEY_N: return 57;  // A3
        case GDK_KEY_j: case GDK_KEY_J: return 58;  // A#3
        case GDK_KEY_m: case GDK_KEY_M: return 59;  // B3

        // Upper octave (C4 = 60)
        case GDK_KEY_q: case GDK_KEY_Q: return 60;  // C4 (middle C)
        case GDK_KEY_2: return 61;  // C#4
        case GDK_KEY_w: case GDK_KEY_W: return 62;  // D4
        case GDK_KEY_3: return 63;  // D#4
        case GDK_KEY_e: case GDK_KEY_E: return 64;  // E4
        case GDK_KEY_r: case GDK_KEY_R: return 65;  // F4
        case GDK_KEY_5: return 66;  // F#4
        case GDK_KEY_t: case GDK_KEY_T: return 67;  // G4
        case GDK_KEY_6: return 68;  // G#4
        case GDK_KEY_y: case GDK_KEY_Y: return 69;  // A4 (440Hz)
        case GDK_KEY_7: return 70;  // A#4
        case GDK_KEY_u: case GDK_KEY_U: return 71;  // B4
        case GDK_KEY_i: case GDK_KEY_I: return 72;  // C5
        case GDK_KEY_9: return 73;  // C#5
        case GDK_KEY_o: case GDK_KEY_O: return 74;  // D5
        case GDK_KEY_0: return 75;  // D#5
        case GDK_KEY_p: case GDK_KEY_P: return 76;  // E5

        default: return -1;
    }
}

// Forward declarations
static void draw_piano(GtkDrawingArea *area, cairo_t *cr, int width, int height, gpointer user_data);
static void on_piano_pressed(GtkGestureClick *gesture, int n_press, double x, double y, gpointer user_data);
static void on_piano_released(GtkGestureClick *gesture, int n_press, double x, double y, gpointer user_data);
static void on_piano_motion(GtkEventControllerMotion *controller, double x, double y, gpointer user_data);
static gboolean on_key_pressed(GtkEventControllerKey *controller, guint keyval, guint keycode, GdkModifierType state, gpointer user_data);
static void on_key_released(GtkEventControllerKey *controller, guint keyval, guint keycode, GdkModifierType state, gpointer user_data);
static void on_instrument_changed(GtkDropDown *dropdown, GParamSpec *pspec, gpointer user_data);
static gboolean on_scale_lock_toggled(GtkSwitch *sw, gboolean state, gpointer user_data);
static void on_scale_type_changed(GtkDropDown *dropdown, GParamSpec *pspec, gpointer user_data);
static void on_root_note_changed(GtkDropDown *dropdown, GParamSpec *pspec, gpointer user_data);
static void update_params_ui(InstrumentModal *modal);

// Check if note is a black key
static bool is_black_key(int note) {
    int n = note % 12;
    return (n == 1 || n == 3 || n == 6 || n == 8 || n == 10);
}

// Get white key index for a note (0-based from PIANO_START_NOTE)
static int get_white_key_index(int note) {
    int white_keys = 0;
    for (int n = PIANO_START_NOTE; n < note; n++) {
        if (!is_black_key(n)) white_keys++;
    }
    return white_keys;
}

// Get total number of white keys
static int get_white_key_count(void) {
    int count = 0;
    for (int n = PIANO_START_NOTE; n <= PIANO_END_NOTE; n++) {
        if (!is_black_key(n)) count++;
    }
    return count;
}

// Get note at x position
static int get_note_at_position(InstrumentModal *modal, double x, double y) {
    (void)modal;

    int white_key_count = get_white_key_count();
    int piano_width = white_key_count * WHITE_KEY_WIDTH;

    if (x < 0 || x >= piano_width || y < 0 || y >= WHITE_KEY_HEIGHT) {
        return -1;
    }

    // Check black keys first (they're on top)
    if (y < BLACK_KEY_HEIGHT) {
        for (int note = PIANO_START_NOTE; note <= PIANO_END_NOTE; note++) {
            if (!is_black_key(note)) continue;

            // Black keys are positioned relative to white keys
            int white_idx = get_white_key_index(note);
            int black_x = white_idx * WHITE_KEY_WIDTH - BLACK_KEY_WIDTH / 2;

            if (x >= black_x && x < black_x + BLACK_KEY_WIDTH) {
                return note;
            }
        }
    }

    // Check white keys
    int white_idx = (int)(x / WHITE_KEY_WIDTH);
    int white_count = 0;
    for (int note = PIANO_START_NOTE; note <= PIANO_END_NOTE; note++) {
        if (!is_black_key(note)) {
            if (white_count == white_idx) {
                return note;
            }
            white_count++;
        }
    }

    return -1;
}

// Draw piano keyboard
static void draw_piano(GtkDrawingArea *area, cairo_t *cr, int width, int height, gpointer user_data) {
    (void)area;
    (void)width;
    (void)height;

    InstrumentModal *modal = (InstrumentModal *)user_data;
    if (!modal) return;

    // Check scale lock state
    bool show_scale = modal->scale_lock_enabled && modal->scale_type > 0;

    // Draw white keys first
    int white_idx = 0;
    for (int note = PIANO_START_NOTE; note <= PIANO_END_NOTE; note++) {
        if (is_black_key(note)) continue;

        int x = white_idx * WHITE_KEY_WIDTH;
        bool pressed = modal->keys_pressed[note];
        bool hover = (note == modal->hover_note);
        bool in_scale = !show_scale || scale_contains_note(modal->scale_type, modal->root_note, note);
        bool is_root = show_scale && ((note % 12) == modal->root_note);

        // Key fill
        if (pressed) {
            cairo_set_source_rgb(cr, COLOR_WHITE_KEY_PRESSED.r, COLOR_WHITE_KEY_PRESSED.g, COLOR_WHITE_KEY_PRESSED.b);
        } else if (hover) {
            cairo_set_source_rgb(cr, 0.9, 0.9, 0.95);
        } else if (is_root) {
            cairo_set_source_rgb(cr, COLOR_ROOT_KEY.r, COLOR_ROOT_KEY.g, COLOR_ROOT_KEY.b);
        } else if (!in_scale) {
            cairo_set_source_rgb(cr, COLOR_WHITE_KEY_OUT_OF_SCALE.r, COLOR_WHITE_KEY_OUT_OF_SCALE.g, COLOR_WHITE_KEY_OUT_OF_SCALE.b);
        } else {
            cairo_set_source_rgb(cr, COLOR_WHITE_KEY.r, COLOR_WHITE_KEY.g, COLOR_WHITE_KEY.b);
        }
        cairo_rectangle(cr, x, 0, WHITE_KEY_WIDTH - 1, WHITE_KEY_HEIGHT);
        cairo_fill(cr);

        // Key border
        cairo_set_source_rgb(cr, COLOR_KEY_BORDER.r, COLOR_KEY_BORDER.g, COLOR_KEY_BORDER.b);
        cairo_set_line_width(cr, 1.0);
        cairo_rectangle(cr, x, 0, WHITE_KEY_WIDTH - 1, WHITE_KEY_HEIGHT);
        cairo_stroke(cr);

        // Note name for C keys
        if (note % 12 == 0) {
            cairo_set_source_rgb(cr, 0.3, 0.3, 0.35);
            cairo_select_font_face(cr, "Sans", CAIRO_FONT_SLANT_NORMAL, CAIRO_FONT_WEIGHT_NORMAL);
            cairo_set_font_size(cr, 10);
            char label[8];
            snprintf(label, sizeof(label), "C%d", (note / 12) - 1);
            cairo_move_to(cr, x + 4, WHITE_KEY_HEIGHT - 8);
            cairo_show_text(cr, label);
        }

        white_idx++;
    }

    // Draw black keys on top
    for (int note = PIANO_START_NOTE; note <= PIANO_END_NOTE; note++) {
        if (!is_black_key(note)) continue;

        int white_idx_before = get_white_key_index(note);
        int x = white_idx_before * WHITE_KEY_WIDTH - BLACK_KEY_WIDTH / 2;

        bool pressed = modal->keys_pressed[note];
        bool hover = (note == modal->hover_note);
        bool in_scale = !show_scale || scale_contains_note(modal->scale_type, modal->root_note, note);

        // Key fill
        if (pressed) {
            cairo_set_source_rgb(cr, COLOR_BLACK_KEY_PRESSED.r, COLOR_BLACK_KEY_PRESSED.g, COLOR_BLACK_KEY_PRESSED.b);
        } else if (hover) {
            cairo_set_source_rgb(cr, 0.25, 0.25, 0.3);
        } else if (!in_scale) {
            cairo_set_source_rgb(cr, COLOR_BLACK_KEY_OUT_OF_SCALE.r, COLOR_BLACK_KEY_OUT_OF_SCALE.g, COLOR_BLACK_KEY_OUT_OF_SCALE.b);
        } else {
            cairo_set_source_rgb(cr, COLOR_BLACK_KEY.r, COLOR_BLACK_KEY.g, COLOR_BLACK_KEY.b);
        }
        cairo_rectangle(cr, x, 0, BLACK_KEY_WIDTH, BLACK_KEY_HEIGHT);
        cairo_fill(cr);

        // Key border (subtle)
        cairo_set_source_rgb(cr, 0.1, 0.1, 0.12);
        cairo_set_line_width(cr, 0.5);
        cairo_rectangle(cr, x, 0, BLACK_KEY_WIDTH, BLACK_KEY_HEIGHT);
        cairo_stroke(cr);
    }
}

// Mouse pressed on piano
static void on_piano_pressed(GtkGestureClick *gesture, int n_press, double x, double y, gpointer user_data) {
    (void)gesture;
    (void)n_press;

    InstrumentModal *modal = (InstrumentModal *)user_data;
    if (!modal) return;

    int note = get_note_at_position(modal, x, y);
    if (note >= 0 && note < 128) {
        modal->keys_pressed[note] = true;
        audio_engine_note_on(modal->audio_engine, modal->track, note, 100);
        gtk_widget_queue_draw(modal->piano_area);
    }
}

// Mouse released on piano
static void on_piano_released(GtkGestureClick *gesture, int n_press, double x, double y, gpointer user_data) {
    (void)gesture;
    (void)n_press;
    (void)x;
    (void)y;

    InstrumentModal *modal = (InstrumentModal *)user_data;
    if (!modal) return;

    // Release all pressed keys
    for (int i = 0; i < 128; i++) {
        if (modal->keys_pressed[i]) {
            modal->keys_pressed[i] = false;
            audio_engine_note_off(modal->audio_engine, modal->track, i);
        }
    }
    gtk_widget_queue_draw(modal->piano_area);
}

// Mouse motion on piano
static void on_piano_motion(GtkEventControllerMotion *controller, double x, double y, gpointer user_data) {
    (void)controller;

    InstrumentModal *modal = (InstrumentModal *)user_data;
    if (!modal) return;

    int note = get_note_at_position(modal, x, y);
    if (note != modal->hover_note) {
        modal->hover_note = note;
        gtk_widget_queue_draw(modal->piano_area);
    }
}

// QWERTY keyboard pressed
static gboolean on_key_pressed(GtkEventControllerKey *controller, guint keyval, guint keycode, GdkModifierType state, gpointer user_data) {
    (void)controller;
    (void)keycode;
    (void)state;

    InstrumentModal *modal = (InstrumentModal *)user_data;
    if (!modal) return FALSE;

    int note = qwerty_to_note(keyval);
    if (note >= 0 && note < 128) {
        // Apply scale lock quantization if enabled
        int play_note = note;
        if (modal->scale_lock_enabled && modal->scale_type > 0) {
            play_note = scale_quantize_note(modal->scale_type, modal->root_note, note);
        }

        // Only trigger if not already pressed (prevent key repeat)
        if (!modal->keys_pressed[play_note]) {
            modal->keys_pressed[play_note] = true;
            audio_engine_note_on(modal->audio_engine, modal->track, play_note, 100);
            if (modal->piano_area) {
                gtk_widget_queue_draw(modal->piano_area);
            }
        }
        return TRUE;
    }

    return FALSE;
}

// QWERTY keyboard released
static void on_key_released(GtkEventControllerKey *controller, guint keyval, guint keycode, GdkModifierType state, gpointer user_data) {
    (void)controller;
    (void)keycode;
    (void)state;

    InstrumentModal *modal = (InstrumentModal *)user_data;
    if (!modal) return;

    int note = qwerty_to_note(keyval);
    if (note >= 0 && note < 128) {
        // Apply scale lock quantization if enabled (same as on_key_pressed)
        int play_note = note;
        if (modal->scale_lock_enabled && modal->scale_type > 0) {
            play_note = scale_quantize_note(modal->scale_type, modal->root_note, note);
        }

        if (modal->keys_pressed[play_note]) {
            modal->keys_pressed[play_note] = false;
            audio_engine_note_off(modal->audio_engine, modal->track, play_note);
            if (modal->piano_area) {
                gtk_widget_queue_draw(modal->piano_area);
            }
        }
    }
}

// Instrument selection changed
static void on_instrument_changed(GtkDropDown *dropdown, GParamSpec *pspec, gpointer user_data) {
    (void)pspec;

    InstrumentModal *modal = (InstrumentModal *)user_data;
    if (!modal) return;

    guint selected = gtk_drop_down_get_selected(dropdown);

    if (selected == 0) {
        // "None" selected - remove instrument
        audio_engine_remove_track_instrument(modal->audio_engine, modal->track);
        gtk_label_set_text(GTK_LABEL(modal->instrument_name_label), "No instrument loaded");
    } else {
        // Set instrument (index - 1 because "None" is at index 0)
        int result = audio_engine_set_track_instrument(modal->audio_engine, modal->track, (int)(selected - 1));
        if (result == 0) {
            const char *name = audio_engine_get_track_instrument_name(modal->audio_engine, modal->track);
            gtk_label_set_text(GTK_LABEL(modal->instrument_name_label), name);
        } else {
            gtk_label_set_text(GTK_LABEL(modal->instrument_name_label), "Failed to load instrument");
        }
    }

    update_params_ui(modal);
}

// Scale lock toggle changed
static gboolean on_scale_lock_toggled(GtkSwitch *sw, gboolean state, gpointer user_data) {
    (void)sw;
    InstrumentModal *modal = (InstrumentModal *)user_data;
    if (!modal) return FALSE;

    modal->scale_lock_enabled = state;
    gtk_widget_set_sensitive(modal->scale_dropdown, state);
    gtk_widget_set_sensitive(modal->root_dropdown, state);

    // Redraw piano to show scale highlighting
    gtk_widget_queue_draw(modal->piano_area);

    printf("🎹 Scale lock %s (scale=%d, root=%d)\n",
           state ? "enabled" : "disabled", modal->scale_type, modal->root_note);

    return FALSE;  // Let the switch update its state
}

// Scale type selection changed
static void on_scale_type_changed(GtkDropDown *dropdown, GParamSpec *pspec, gpointer user_data) {
    (void)pspec;
    InstrumentModal *modal = (InstrumentModal *)user_data;
    if (!modal) return;

    modal->scale_type = (int)gtk_drop_down_get_selected(dropdown);

    // Redraw piano to show updated scale highlighting
    if (modal->scale_lock_enabled) {
        gtk_widget_queue_draw(modal->piano_area);
    }

    printf("🎹 Scale changed to: %s\n", scale_get_name(modal->scale_type));
}

// Root note selection changed
static void on_root_note_changed(GtkDropDown *dropdown, GParamSpec *pspec, gpointer user_data) {
    (void)pspec;
    InstrumentModal *modal = (InstrumentModal *)user_data;
    if (!modal) return;

    modal->root_note = (int)gtk_drop_down_get_selected(dropdown);

    // Redraw piano to show updated scale highlighting
    if (modal->scale_lock_enabled) {
        gtk_widget_queue_draw(modal->piano_area);
    }

    printf("🎹 Root changed to: %s\n", scale_get_root_name(modal->root_note));
}

// Callback adapter: bridges DawValueChangedCallback to audio engine
static void on_param_widget_changed(float value, int param_index, void *user_data) {
    InstrumentModal *modal = (InstrumentModal *)user_data;
    if (!modal) return;

    // Update engine with new parameter value
    audio_engine_set_track_instrument_param(modal->audio_engine, modal->track, param_index, value);
}

// Helper to create a parameter widget (knob, small knob, slider, etc.)
static GtkWidget* create_param_widget(InstrumentModal *modal, int i, bool use_small_knob) {
    const char *name = audio_engine_get_track_instrument_param_name(modal->audio_engine, modal->track, i);
    float value = audio_engine_get_track_instrument_param_value(modal->audio_engine, modal->track, i);
    float min = audio_engine_get_track_instrument_param_min(modal->audio_engine, modal->track, i);
    float max = audio_engine_get_track_instrument_param_max(modal->audio_engine, modal->track, i);
    const char *unit = audio_engine_get_track_instrument_param_unit(modal->audio_engine, modal->track, i);

    if (use_small_knob) {
        return daw_small_knob_new(name, value, min, max, unit, i, on_param_widget_changed, modal);
    }

    // Use suggested widget type
    DawWidgetType type = daw_suggest_widget_type(name, min, max);
    switch (type) {
        case DAW_WIDGET_VSLIDER:
            return daw_vslider_new(name, value, min, max, unit, i, on_param_widget_changed, modal);
        case DAW_WIDGET_HSLIDER:
            // For compact layout, convert horizontal sliders to regular knobs
            return daw_knob_new(name, value, min, max, unit, i, on_param_widget_changed, modal);
        case DAW_WIDGET_KNOB:
        default:
            return daw_knob_new(name, value, min, max, unit, i, on_param_widget_changed, modal);
    }
}

// FM Synth compact layout (12 params)
// Row 1: [Algorithm] [Mod Depth] [Feedback] [Brightness] | [Volume]
// Row 2: [Op2 Ratio] [Op3 Ratio] [Op4 Ratio]  (small knobs)
// Row 3: [Attack] [Decay] [Sustain] [Release]  (small knobs)
static void create_fm_synth_layout(InstrumentModal *modal, GtkWidget *container) {
    GtkWidget *main_box = gtk_box_new(GTK_ORIENTATION_VERTICAL, 12);
    gtk_widget_set_margin_top(main_box, 8);

    // Row 1: Main controls + Volume
    GtkWidget *row1 = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 16);
    gtk_widget_set_halign(row1, GTK_ALIGN_CENTER);

    // Algorithm, Mod Depth, Feedback, Brightness (indices 0, 1, 2, 11)
    gtk_box_append(GTK_BOX(row1), create_param_widget(modal, 0, false));  // Algorithm
    gtk_box_append(GTK_BOX(row1), create_param_widget(modal, 1, false));  // Mod Depth
    gtk_box_append(GTK_BOX(row1), create_param_widget(modal, 2, false));  // Feedback
    gtk_box_append(GTK_BOX(row1), create_param_widget(modal, 11, false)); // Brightness

    // Separator before volume
    GtkWidget *sep1 = gtk_separator_new(GTK_ORIENTATION_VERTICAL);
    gtk_widget_set_margin_start(sep1, 8);
    gtk_widget_set_margin_end(sep1, 8);
    gtk_box_append(GTK_BOX(row1), sep1);

    // Volume (index 10)
    gtk_box_append(GTK_BOX(row1), create_param_widget(modal, 10, false));

    gtk_box_append(GTK_BOX(main_box), row1);

    // Row 2: Operator Ratios (small knobs)
    GtkWidget *row2_frame = gtk_frame_new("Operators");
    GtkWidget *row2 = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 12);
    gtk_widget_set_halign(row2, GTK_ALIGN_CENTER);
    gtk_widget_set_margin_start(row2, 12);
    gtk_widget_set_margin_end(row2, 12);
    gtk_widget_set_margin_top(row2, 8);
    gtk_widget_set_margin_bottom(row2, 8);

    // Op2, Op3, Op4 Ratios (indices 3, 4, 5)
    gtk_box_append(GTK_BOX(row2), create_param_widget(modal, 3, true));   // Op2 Ratio
    gtk_box_append(GTK_BOX(row2), create_param_widget(modal, 4, true));   // Op3 Ratio
    gtk_box_append(GTK_BOX(row2), create_param_widget(modal, 5, true));   // Op4 Ratio

    gtk_frame_set_child(GTK_FRAME(row2_frame), row2);
    gtk_box_append(GTK_BOX(main_box), row2_frame);

    // Row 3: ADSR (small knobs)
    GtkWidget *row3_frame = gtk_frame_new("Envelope");
    GtkWidget *row3 = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 12);
    gtk_widget_set_halign(row3, GTK_ALIGN_CENTER);
    gtk_widget_set_margin_start(row3, 12);
    gtk_widget_set_margin_end(row3, 12);
    gtk_widget_set_margin_top(row3, 8);
    gtk_widget_set_margin_bottom(row3, 8);

    // Attack, Decay, Sustain, Release (indices 6, 7, 8, 9)
    gtk_box_append(GTK_BOX(row3), create_param_widget(modal, 6, true));   // Attack
    gtk_box_append(GTK_BOX(row3), create_param_widget(modal, 7, true));   // Decay
    gtk_box_append(GTK_BOX(row3), create_param_widget(modal, 8, true));   // Sustain
    gtk_box_append(GTK_BOX(row3), create_param_widget(modal, 9, true));   // Release

    gtk_frame_set_child(GTK_FRAME(row3_frame), row3);
    gtk_box_append(GTK_BOX(main_box), row3_frame);

    gtk_box_append(GTK_BOX(container), main_box);
}

// SuperSaw compact layout (10 params)
// Row 1: [Detune] [Voices] [Cutoff] [Res] [Filter Env] | [Volume]
// Row 2: [Attack] [Decay] [Sustain] [Release]  (small knobs)
static void create_supersaw_layout(InstrumentModal *modal, GtkWidget *container) {
    GtkWidget *main_box = gtk_box_new(GTK_ORIENTATION_VERTICAL, 12);
    gtk_widget_set_margin_top(main_box, 8);

    // Row 1: Main controls + Volume
    GtkWidget *row1 = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 16);
    gtk_widget_set_halign(row1, GTK_ALIGN_CENTER);

    // Detune, Voices, Cutoff, Res, Filter Env (indices 0, 1, 2, 3, 4)
    gtk_box_append(GTK_BOX(row1), create_param_widget(modal, 0, false));  // Detune
    gtk_box_append(GTK_BOX(row1), create_param_widget(modal, 1, false));  // Voices
    gtk_box_append(GTK_BOX(row1), create_param_widget(modal, 2, false));  // Filter Cutoff
    gtk_box_append(GTK_BOX(row1), create_param_widget(modal, 3, false));  // Filter Res
    gtk_box_append(GTK_BOX(row1), create_param_widget(modal, 4, false));  // Filter Env

    // Separator before volume
    GtkWidget *sep1 = gtk_separator_new(GTK_ORIENTATION_VERTICAL);
    gtk_widget_set_margin_start(sep1, 8);
    gtk_widget_set_margin_end(sep1, 8);
    gtk_box_append(GTK_BOX(row1), sep1);

    // Volume (index 9)
    gtk_box_append(GTK_BOX(row1), create_param_widget(modal, 9, false));

    gtk_box_append(GTK_BOX(main_box), row1);

    // Row 2: ADSR (small knobs)
    GtkWidget *row2_frame = gtk_frame_new("Envelope");
    GtkWidget *row2 = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 12);
    gtk_widget_set_halign(row2, GTK_ALIGN_CENTER);
    gtk_widget_set_margin_start(row2, 12);
    gtk_widget_set_margin_end(row2, 12);
    gtk_widget_set_margin_top(row2, 8);
    gtk_widget_set_margin_bottom(row2, 8);

    // Attack, Decay, Sustain, Release (indices 5, 6, 7, 8)
    gtk_box_append(GTK_BOX(row2), create_param_widget(modal, 5, true));   // Attack
    gtk_box_append(GTK_BOX(row2), create_param_widget(modal, 6, true));   // Decay
    gtk_box_append(GTK_BOX(row2), create_param_widget(modal, 7, true));   // Sustain
    gtk_box_append(GTK_BOX(row2), create_param_widget(modal, 8, true));   // Release

    gtk_frame_set_child(GTK_FRAME(row2_frame), row2);
    gtk_box_append(GTK_BOX(main_box), row2_frame);

    gtk_box_append(GTK_BOX(container), main_box);
}

// Wavetable compact layout (12 params)
// Row 1: [Osc1 Pos] [Osc2 Pos] [Mix] [Sub] | [Volume]
// Row 2: [Cutoff] [Res] [Filter Env] [LFO Rate] [LFO→WT]
// Row 3: [Detune] [Attack]  (small knobs)
static void create_wavetable_layout(InstrumentModal *modal, GtkWidget *container) {
    GtkWidget *main_box = gtk_box_new(GTK_ORIENTATION_VERTICAL, 12);
    gtk_widget_set_margin_top(main_box, 8);

    // Row 1: Oscillator controls + Volume
    GtkWidget *row1 = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 16);
    gtk_widget_set_halign(row1, GTK_ALIGN_CENTER);

    // Osc1 Pos, Osc2 Pos, Mix, Sub (indices 0, 1, 2, 3)
    gtk_box_append(GTK_BOX(row1), create_param_widget(modal, 0, false));  // Osc1 WT Pos
    gtk_box_append(GTK_BOX(row1), create_param_widget(modal, 1, false));  // Osc2 WT Pos
    gtk_box_append(GTK_BOX(row1), create_param_widget(modal, 2, false));  // Osc Mix
    gtk_box_append(GTK_BOX(row1), create_param_widget(modal, 3, false));  // Sub Level

    // Separator before volume
    GtkWidget *sep1 = gtk_separator_new(GTK_ORIENTATION_VERTICAL);
    gtk_widget_set_margin_start(sep1, 8);
    gtk_widget_set_margin_end(sep1, 8);
    gtk_box_append(GTK_BOX(row1), sep1);

    // Volume (index 10)
    gtk_box_append(GTK_BOX(row1), create_param_widget(modal, 10, false));

    gtk_box_append(GTK_BOX(main_box), row1);

    // Row 2: Filter + LFO (small knobs for compact)
    GtkWidget *row2_frame = gtk_frame_new("Filter & LFO");
    GtkWidget *row2 = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 12);
    gtk_widget_set_halign(row2, GTK_ALIGN_CENTER);
    gtk_widget_set_margin_start(row2, 12);
    gtk_widget_set_margin_end(row2, 12);
    gtk_widget_set_margin_top(row2, 8);
    gtk_widget_set_margin_bottom(row2, 8);

    // Cutoff, Res, Filter Env, LFO Rate, LFO->WT1 (indices 5, 6, 7, 8, 9)
    gtk_box_append(GTK_BOX(row2), create_param_widget(modal, 5, true));   // Filter Cutoff
    gtk_box_append(GTK_BOX(row2), create_param_widget(modal, 6, true));   // Filter Res
    gtk_box_append(GTK_BOX(row2), create_param_widget(modal, 7, true));   // Filter Env
    gtk_box_append(GTK_BOX(row2), create_param_widget(modal, 8, true));   // LFO1 Rate
    gtk_box_append(GTK_BOX(row2), create_param_widget(modal, 9, true));   // LFO1 -> WT1

    gtk_frame_set_child(GTK_FRAME(row2_frame), row2);
    gtk_box_append(GTK_BOX(main_box), row2_frame);

    // Row 3: Detune + Attack (small knobs)
    GtkWidget *row3_frame = gtk_frame_new("Tuning & Envelope");
    GtkWidget *row3 = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 12);
    gtk_widget_set_halign(row3, GTK_ALIGN_CENTER);
    gtk_widget_set_margin_start(row3, 12);
    gtk_widget_set_margin_end(row3, 12);
    gtk_widget_set_margin_top(row3, 8);
    gtk_widget_set_margin_bottom(row3, 8);

    // Detune, Attack (indices 4, 11)
    gtk_box_append(GTK_BOX(row3), create_param_widget(modal, 4, true));   // Detune
    gtk_box_append(GTK_BOX(row3), create_param_widget(modal, 11, true));  // Attack

    gtk_frame_set_child(GTK_FRAME(row3_frame), row3);
    gtk_box_append(GTK_BOX(main_box), row3_frame);

    gtk_box_append(GTK_BOX(container), main_box);
}

// Update parameter UI based on current instrument
static void update_params_ui(InstrumentModal *modal) {
    // Clear existing parameter widgets
    GtkWidget *child = gtk_widget_get_first_child(modal->params_box);
    while (child) {
        GtkWidget *next = gtk_widget_get_next_sibling(child);
        gtk_box_remove(GTK_BOX(modal->params_box), child);
        child = next;
    }

    // Reset pointers
    for (int i = 0; i < 16; i++) {
        modal->param_sliders[i] = NULL;
        modal->param_labels[i] = NULL;
    }

    // Check if track has instrument
    if (!audio_engine_track_has_instrument(modal->audio_engine, modal->track)) {
        GtkWidget *no_params = gtk_label_new("Load an instrument to see parameters");
        gtk_widget_set_margin_top(no_params, 40);
        gtk_widget_set_opacity(no_params, 0.6);
        gtk_box_append(GTK_BOX(modal->params_box), no_params);
        return;
    }

    int param_count = audio_engine_get_track_instrument_param_count(modal->audio_engine, modal->track);

    if (param_count == 0) {
        GtkWidget *no_params = gtk_label_new("No parameters available");
        gtk_widget_set_margin_top(no_params, 40);
        gtk_widget_set_opacity(no_params, 0.6);
        gtk_box_append(GTK_BOX(modal->params_box), no_params);
        return;
    }

    // Check instrument type and use appropriate compact layout
    const char *inst_name = audio_engine_get_track_instrument_name(modal->audio_engine, modal->track);

    if (strcmp(inst_name, "FM Synth") == 0 && param_count >= 12) {
        create_fm_synth_layout(modal, modal->params_box);
        return;
    }

    if (strcmp(inst_name, "SuperSaw") == 0 && param_count >= 10) {
        create_supersaw_layout(modal, modal->params_box);
        return;
    }

    if (strcmp(inst_name, "WavetableSynth") == 0 && param_count >= 12) {
        create_wavetable_layout(modal, modal->params_box);
        return;
    }

    // Generic layout for Keys and unknown instruments
    // Collect parameters by widget type
    int knob_params[16], knob_count = 0;
    int vslider_params[16], vslider_count = 0;
    int hslider_params[16], hslider_count = 0;

    for (int i = 0; i < param_count && i < 16; i++) {
        const char *name = audio_engine_get_track_instrument_param_name(modal->audio_engine, modal->track, i);
        float min = audio_engine_get_track_instrument_param_min(modal->audio_engine, modal->track, i);
        float max = audio_engine_get_track_instrument_param_max(modal->audio_engine, modal->track, i);

        DawWidgetType type = daw_suggest_widget_type(name, min, max);
        switch (type) {
            case DAW_WIDGET_KNOB:
                knob_params[knob_count++] = i;
                break;
            case DAW_WIDGET_VSLIDER:
                vslider_params[vslider_count++] = i;
                break;
            case DAW_WIDGET_HSLIDER:
                hslider_params[hslider_count++] = i;
                break;
        }
    }

    // Main layout container
    GtkWidget *main_layout = gtk_box_new(GTK_ORIENTATION_VERTICAL, 16);
    gtk_widget_set_margin_top(main_layout, 8);

    // Row 1: Knobs + Volume slider
    if (knob_count > 0 || vslider_count > 0) {
        GtkWidget *top_row = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 24);
        gtk_widget_set_halign(top_row, GTK_ALIGN_CENTER);

        for (int k = 0; k < knob_count; k++) {
            gtk_box_append(GTK_BOX(top_row), create_param_widget(modal, knob_params[k], false));
        }

        if (knob_count > 0 && vslider_count > 0) {
            GtkWidget *sep = gtk_separator_new(GTK_ORIENTATION_VERTICAL);
            gtk_widget_set_margin_start(sep, 12);
            gtk_widget_set_margin_end(sep, 12);
            gtk_box_append(GTK_BOX(top_row), sep);
        }

        for (int v = 0; v < vslider_count; v++) {
            gtk_box_append(GTK_BOX(top_row), create_param_widget(modal, vslider_params[v], false));
        }

        gtk_box_append(GTK_BOX(main_layout), top_row);
    }

    // Row 2: Horizontal sliders (converted to knobs for compact layout)
    if (hslider_count > 0) {
        GtkWidget *sliders_frame = gtk_frame_new(NULL);
        gtk_widget_set_margin_top(sliders_frame, 8);

        GtkWidget *sliders_box = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 12);
        gtk_widget_set_halign(sliders_box, GTK_ALIGN_CENTER);
        gtk_widget_set_margin_start(sliders_box, 12);
        gtk_widget_set_margin_end(sliders_box, 12);
        gtk_widget_set_margin_top(sliders_box, 8);
        gtk_widget_set_margin_bottom(sliders_box, 8);

        for (int h = 0; h < hslider_count; h++) {
            // Use small knobs instead of horizontal sliders for compact layout
            gtk_box_append(GTK_BOX(sliders_box), create_param_widget(modal, hslider_params[h], true));
        }

        gtk_frame_set_child(GTK_FRAME(sliders_frame), sliders_box);
        gtk_box_append(GTK_BOX(main_layout), sliders_frame);
    }

    gtk_box_append(GTK_BOX(modal->params_box), main_layout);
}

// Handle window close - hide instead of destroy
static gboolean on_window_close_request(GtkWindow *window, gpointer user_data) {
    InstrumentModal *modal = (InstrumentModal *)user_data;
    if (!modal) return FALSE;

    // Release all notes when hiding
    for (int i = 0; i < 128; i++) {
        if (modal->keys_pressed[i]) {
            audio_engine_note_off(modal->audio_engine, modal->track, i);
            modal->keys_pressed[i] = false;
        }
    }

    // Hide window instead of destroying
    gtk_widget_set_visible(GTK_WIDGET(window), FALSE);

    return TRUE;  // Prevent default destroy behavior
}

// Create the instrument modal
InstrumentModal* instrument_modal_new(GtkWindow *parent, void *audio_engine, int track) {
    InstrumentModal *modal = malloc(sizeof(InstrumentModal));
    if (!modal) return NULL;

    memset(modal, 0, sizeof(InstrumentModal));
    modal->audio_engine = audio_engine;
    modal->track = track;
    modal->hover_note = -1;

    // Create window (not modal - modal blocks dropdowns on macOS)
    modal->window = gtk_window_new();
    char title[64];
    snprintf(title, sizeof(title), "Track %d - Instrument", track + 1);
    gtk_window_set_title(GTK_WINDOW(modal->window), title);
    gtk_window_set_default_size(GTK_WINDOW(modal->window), MODAL_WIDTH, MODAL_HEIGHT);
    gtk_window_set_resizable(GTK_WINDOW(modal->window), TRUE);
    // Note: Not using gtk_window_set_modal(TRUE) as it blocks dropdown popovers on macOS

    if (parent) {
        gtk_window_set_transient_for(GTK_WINDOW(modal->window), parent);
    }

    // Handle close button - hide instead of destroy
    g_signal_connect(modal->window, "close-request", G_CALLBACK(on_window_close_request), modal);

    // Main container
    GtkWidget *main_box = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0);

    // Header with instrument selector
    GtkWidget *header_box = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 12);
    gtk_widget_set_margin_start(header_box, 16);
    gtk_widget_set_margin_end(header_box, 16);
    gtk_widget_set_margin_top(header_box, 12);
    gtk_widget_set_margin_bottom(header_box, 12);

    // Instrument selector label
    GtkWidget *inst_label = gtk_label_new("Instrument:");
    gtk_box_append(GTK_BOX(header_box), inst_label);

    // Build instrument list
    int inst_count = audio_engine_get_instrument_type_count();
    char **inst_names = malloc((inst_count + 2) * sizeof(char *));
    inst_names[0] = g_strdup("None");
    for (int i = 0; i < inst_count; i++) {
        inst_names[i + 1] = g_strdup(audio_engine_get_instrument_type_name(i));
    }
    inst_names[inst_count + 1] = NULL;

    modal->instrument_dropdown = gtk_drop_down_new_from_strings((const char * const *)inst_names);

    // Free temp strings
    for (int i = 0; i <= inst_count; i++) {
        g_free(inst_names[i]);
    }
    free(inst_names);

    gtk_widget_set_size_request(modal->instrument_dropdown, 200, -1);
    g_signal_connect(modal->instrument_dropdown, "notify::selected", G_CALLBACK(on_instrument_changed), modal);
    gtk_box_append(GTK_BOX(header_box), modal->instrument_dropdown);

    // Current instrument name
    const char *current_name = audio_engine_track_has_instrument(audio_engine, track)
        ? audio_engine_get_track_instrument_name(audio_engine, track)
        : "No instrument loaded";
    modal->instrument_name_label = gtk_label_new(NULL);
    char markup[256];
    snprintf(markup, sizeof(markup), "<span foreground='" TOKYONIGHT_CYAN "' weight='bold'>%s</span>", current_name);
    gtk_label_set_markup(GTK_LABEL(modal->instrument_name_label), markup);
    gtk_widget_set_hexpand(modal->instrument_name_label, TRUE);
    gtk_widget_set_halign(modal->instrument_name_label, GTK_ALIGN_END);
    gtk_box_append(GTK_BOX(header_box), modal->instrument_name_label);

    gtk_box_append(GTK_BOX(main_box), header_box);

    // Separator
    GtkWidget *sep1 = gtk_separator_new(GTK_ORIENTATION_HORIZONTAL);
    gtk_box_append(GTK_BOX(main_box), sep1);

    // Parameters section
    GtkWidget *params_frame = gtk_frame_new("Parameters");
    gtk_widget_set_margin_start(params_frame, 16);
    gtk_widget_set_margin_end(params_frame, 16);
    gtk_widget_set_margin_top(params_frame, 12);

    modal->params_box = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0);
    gtk_widget_set_margin_start(modal->params_box, 12);
    gtk_widget_set_margin_end(modal->params_box, 12);
    gtk_widget_set_margin_top(modal->params_box, 8);
    gtk_widget_set_margin_bottom(modal->params_box, 12);

    gtk_frame_set_child(GTK_FRAME(params_frame), modal->params_box);
    gtk_box_append(GTK_BOX(main_box), params_frame);

    // Scale Lock section
    GtkWidget *scale_frame = gtk_frame_new("Scale Lock");
    gtk_widget_set_margin_start(scale_frame, 16);
    gtk_widget_set_margin_end(scale_frame, 16);
    gtk_widget_set_margin_top(scale_frame, 12);

    GtkWidget *scale_box = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 16);
    gtk_widget_set_margin_start(scale_box, 12);
    gtk_widget_set_margin_end(scale_box, 12);
    gtk_widget_set_margin_top(scale_box, 8);
    gtk_widget_set_margin_bottom(scale_box, 12);

    // Enable switch
    GtkWidget *enable_box = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8);
    GtkWidget *enable_label = gtk_label_new("Enable:");
    modal->scale_lock_switch = gtk_switch_new();
    gtk_switch_set_active(GTK_SWITCH(modal->scale_lock_switch), FALSE);
    gtk_box_append(GTK_BOX(enable_box), enable_label);
    gtk_box_append(GTK_BOX(enable_box), modal->scale_lock_switch);
    gtk_box_append(GTK_BOX(scale_box), enable_box);

    // Scale dropdown
    GtkWidget *scale_label_box = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8);
    GtkWidget *scale_label = gtk_label_new("Scale:");
    int scale_count = scale_get_count();
    char **scale_names = malloc((scale_count + 1) * sizeof(char *));
    for (int i = 0; i < scale_count; i++) {
        scale_names[i] = g_strdup(scale_get_name(i));
    }
    scale_names[scale_count] = NULL;
    modal->scale_dropdown = gtk_drop_down_new_from_strings((const char * const *)scale_names);
    for (int i = 0; i < scale_count; i++) {
        g_free(scale_names[i]);
    }
    free(scale_names);
    gtk_widget_set_size_request(modal->scale_dropdown, 150, -1);
    gtk_drop_down_set_selected(GTK_DROP_DOWN(modal->scale_dropdown), 1);  // Default to Major
    modal->scale_type = 1;
    gtk_box_append(GTK_BOX(scale_label_box), scale_label);
    gtk_box_append(GTK_BOX(scale_label_box), modal->scale_dropdown);
    gtk_box_append(GTK_BOX(scale_box), scale_label_box);

    // Root note dropdown
    GtkWidget *root_label_box = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8);
    GtkWidget *root_label = gtk_label_new("Root:");
    int root_count = scale_get_root_count();
    char **root_names = malloc((root_count + 1) * sizeof(char *));
    for (int i = 0; i < root_count; i++) {
        root_names[i] = g_strdup(scale_get_root_name(i));
    }
    root_names[root_count] = NULL;
    modal->root_dropdown = gtk_drop_down_new_from_strings((const char * const *)root_names);
    for (int i = 0; i < root_count; i++) {
        g_free(root_names[i]);
    }
    free(root_names);
    gtk_widget_set_size_request(modal->root_dropdown, 80, -1);
    gtk_drop_down_set_selected(GTK_DROP_DOWN(modal->root_dropdown), 0);  // Default to C
    modal->root_note = 0;
    gtk_box_append(GTK_BOX(root_label_box), root_label);
    gtk_box_append(GTK_BOX(root_label_box), modal->root_dropdown);
    gtk_box_append(GTK_BOX(scale_box), root_label_box);

    gtk_frame_set_child(GTK_FRAME(scale_frame), scale_box);
    gtk_box_append(GTK_BOX(main_box), scale_frame);

    // Connect scale lock signals
    g_signal_connect(modal->scale_lock_switch, "state-set", G_CALLBACK(on_scale_lock_toggled), modal);
    g_signal_connect(modal->scale_dropdown, "notify::selected", G_CALLBACK(on_scale_type_changed), modal);
    g_signal_connect(modal->root_dropdown, "notify::selected", G_CALLBACK(on_root_note_changed), modal);

    // Initially disable scale/root dropdowns (until scale lock is enabled)
    gtk_widget_set_sensitive(modal->scale_dropdown, FALSE);
    gtk_widget_set_sensitive(modal->root_dropdown, FALSE);

    // Spacer
    GtkWidget *spacer = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0);
    gtk_widget_set_vexpand(spacer, TRUE);
    gtk_box_append(GTK_BOX(main_box), spacer);

    // Piano keyboard section
    GtkWidget *piano_frame = gtk_frame_new("Keyboard");
    gtk_widget_set_margin_start(piano_frame, 16);
    gtk_widget_set_margin_end(piano_frame, 16);
    gtk_widget_set_margin_bottom(piano_frame, 16);

    // Create scrolled window for piano (it can be wide)
    GtkWidget *piano_scroll = gtk_scrolled_window_new();
    gtk_scrolled_window_set_policy(GTK_SCROLLED_WINDOW(piano_scroll),
                                   GTK_POLICY_AUTOMATIC, GTK_POLICY_NEVER);
    gtk_widget_set_size_request(piano_scroll, -1, WHITE_KEY_HEIGHT + 10);

    // Piano drawing area
    int white_key_count = get_white_key_count();
    int piano_width = white_key_count * WHITE_KEY_WIDTH;

    modal->piano_area = gtk_drawing_area_new();
    gtk_widget_set_size_request(modal->piano_area, piano_width, WHITE_KEY_HEIGHT);
    gtk_drawing_area_set_draw_func(
        GTK_DRAWING_AREA(modal->piano_area),
        (GtkDrawingAreaDrawFunc)draw_piano,
        modal,
        NULL
    );

    // Click gesture for piano
    GtkGesture *click = gtk_gesture_click_new();
    gtk_gesture_single_set_button(GTK_GESTURE_SINGLE(click), GDK_BUTTON_PRIMARY);
    g_signal_connect(click, "pressed", G_CALLBACK(on_piano_pressed), modal);
    g_signal_connect(click, "released", G_CALLBACK(on_piano_released), modal);
    gtk_widget_add_controller(modal->piano_area, GTK_EVENT_CONTROLLER(click));

    // Motion controller for hover effect
    GtkEventController *motion = gtk_event_controller_motion_new();
    g_signal_connect(motion, "motion", G_CALLBACK(on_piano_motion), modal);
    gtk_widget_add_controller(modal->piano_area, motion);

    gtk_scrolled_window_set_child(GTK_SCROLLED_WINDOW(piano_scroll), modal->piano_area);
    gtk_frame_set_child(GTK_FRAME(piano_frame), piano_scroll);
    gtk_box_append(GTK_BOX(main_box), piano_frame);

    gtk_window_set_child(GTK_WINDOW(modal->window), main_box);

    // Add keyboard controller for QWERTY piano input
    GtkEventController *key_controller = gtk_event_controller_key_new();
    g_signal_connect(key_controller, "key-pressed", G_CALLBACK(on_key_pressed), modal);
    g_signal_connect(key_controller, "key-released", G_CALLBACK(on_key_released), modal);
    gtk_widget_add_controller(modal->window, key_controller);

    // Initialize parameters UI
    update_params_ui(modal);

    // Set dropdown to current instrument
    if (audio_engine_track_has_instrument(audio_engine, track)) {
        // Find which instrument type matches
        const char *current = audio_engine_get_track_instrument_name(audio_engine, track);
        for (int i = 0; i < inst_count; i++) {
            if (strcmp(current, audio_engine_get_instrument_type_name(i)) == 0) {
                gtk_drop_down_set_selected(GTK_DROP_DOWN(modal->instrument_dropdown), i + 1);
                break;
            }
        }
    }

    printf("🎹 Instrument modal created for track %d\n", track + 1);

    return modal;
}

void instrument_modal_show(InstrumentModal *modal) {
    if (!modal || !modal->window) return;

    // Refresh UI to show current state from audio engine
    instrument_modal_refresh(modal);

    // Auto-start audio engine if not playing (so instrument can be previewed)
    if (modal->audio_engine && !audio_engine_is_playing(modal->audio_engine)) {
        audio_engine_start(modal->audio_engine);
    }

    gtk_window_present(GTK_WINDOW(modal->window));
}

void instrument_modal_hide(InstrumentModal *modal) {
    if (!modal || !modal->window) return;

    // Release all notes when hiding
    for (int i = 0; i < 128; i++) {
        if (modal->keys_pressed[i]) {
            audio_engine_note_off(modal->audio_engine, modal->track, i);
            modal->keys_pressed[i] = false;
        }
    }

    gtk_widget_set_visible(modal->window, FALSE);
}

void instrument_modal_destroy(InstrumentModal *modal) {
    if (!modal) return;

    // Release all notes
    for (int i = 0; i < 128; i++) {
        if (modal->keys_pressed[i]) {
            audio_engine_note_off(modal->audio_engine, modal->track, i);
        }
    }

    if (modal->window) {
        gtk_window_destroy(GTK_WINDOW(modal->window));
    }

    free(modal);
    printf("🎹 Instrument modal destroyed\n");
}

void instrument_modal_refresh(InstrumentModal *modal) {
    if (!modal) return;

    // Update params UI with current values from engine
    update_params_ui(modal);

    // Update instrument name label and dropdown
    if (audio_engine_track_has_instrument(modal->audio_engine, modal->track)) {
        const char *name = audio_engine_get_track_instrument_name(modal->audio_engine, modal->track);
        char markup[256];
        snprintf(markup, sizeof(markup), "<span foreground='" TOKYONIGHT_CYAN "' weight='bold'>%s</span>", name);
        gtk_label_set_markup(GTK_LABEL(modal->instrument_name_label), markup);

        // Sync dropdown to current instrument
        if (modal->instrument_dropdown) {
            int inst_count = audio_engine_get_instrument_type_count();
            for (int i = 0; i < inst_count; i++) {
                if (strcmp(name, audio_engine_get_instrument_type_name(i)) == 0) {
                    // Block signal to prevent triggering on_instrument_changed
                    g_signal_handlers_block_by_func(modal->instrument_dropdown, on_instrument_changed, modal);
                    gtk_drop_down_set_selected(GTK_DROP_DOWN(modal->instrument_dropdown), i + 1);
                    g_signal_handlers_unblock_by_func(modal->instrument_dropdown, on_instrument_changed, modal);
                    break;
                }
            }
        }
    } else {
        gtk_label_set_text(GTK_LABEL(modal->instrument_name_label), "No instrument loaded");
        // Set dropdown to "None"
        if (modal->instrument_dropdown) {
            g_signal_handlers_block_by_func(modal->instrument_dropdown, on_instrument_changed, modal);
            gtk_drop_down_set_selected(GTK_DROP_DOWN(modal->instrument_dropdown), 0);
            g_signal_handlers_unblock_by_func(modal->instrument_dropdown, on_instrument_changed, modal);
        }
    }
}
