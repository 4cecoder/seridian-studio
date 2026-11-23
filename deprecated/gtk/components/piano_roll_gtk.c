#include "piano_roll_gtk.h"
#include "daw_widgets.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>

// Portable M_PI definition
#ifndef M_PI
#define M_PI 3.14159265358979323846
#endif

// Use shared color scheme from daw_widgets.h
#define BG_COLOR     DAW_COLOR_BG
#define BG_DARK      DAW_COLOR_BG_DARK
#define BG_HIGHLIGHT DAW_COLOR_BG_HIGHLIGHT
#define FG_COLOR     DAW_COLOR_FG
#define FG_DARK      DAW_COLOR_FG_DARK
#define COMMENT      DAW_COLOR_COMMENT
#define CYAN         DAW_COLOR_CYAN
#define GREEN        DAW_COLOR_GREEN
#define BLUE         DAW_COLOR_BLUE
#define PURPLE       DAW_COLOR_PURPLE
#define RED          DAW_COLOR_RED
#define ORANGE       DAW_COLOR_ORANGE
#define YELLOW       DAW_COLOR_YELLOW

// Piano roll constants
#define PIANO_ROLL_HEIGHT 300
#define PIANO_KEY_WIDTH 48
#define NOTE_HEIGHT 14
#define MIN_NOTE 24   // C1
#define MAX_NOTE 108  // C8
#define DEFAULT_PIXELS_PER_BEAT 60.0
#define RESIZE_HANDLE_WIDTH 6
#define VELOCITY_BAR_HEIGHT 40

// MIDI Clip C API declarations
extern int midi_clip_get_note_count(int track);
extern int midi_clip_get_note(int track, int index, unsigned int *out_id,
    double *out_start_beat, double *out_duration, unsigned char *out_pitch,
    unsigned char *out_velocity, int *out_selected);
extern unsigned int midi_clip_add_note(int track, double start_beat, double duration,
    unsigned char pitch, unsigned char velocity);
extern int midi_clip_remove_note(int track, unsigned int note_id);
extern int midi_clip_move_note(int track, unsigned int note_id, double new_beat, unsigned char new_pitch);
extern int midi_clip_resize_note(int track, unsigned int note_id, double new_duration);
extern int midi_clip_set_velocity(int track, unsigned int note_id, unsigned char velocity);
extern int midi_clip_set_selected(int track, unsigned int note_id, int selected);
extern unsigned int midi_clip_find_note_at(int track, double beat, unsigned char pitch);
extern void midi_clip_deselect_all(int track);
extern void midi_clip_select_all(int track);
extern int midi_clip_get_selected_count(int track);
extern int midi_clip_delete_selected(int track);
extern void midi_clip_move_selected(int track, double delta_beat, int delta_pitch);
extern void midi_clip_set_selected_velocity(int track, unsigned char velocity);
extern void midi_clip_quantize_selected(int track, double grid_beats);
extern void midi_clip_select_in_rect(int track, double beat_start, double beat_end,
    unsigned char pitch_low, unsigned char pitch_high, int add_to_selection);
extern int midi_clip_has_notes(int track);
extern void midi_clip_add_demo_notes(int track);

// RGB color struct
typedef struct { double r, g, b; } RGB;

static RGB hex_to_rgb(const char *hex) {
    int r, g, b;
    sscanf(hex + 1, "%02x%02x%02x", &r, &g, &b);
    return (RGB){ r / 255.0, g / 255.0, b / 255.0 };
}

// Interaction modes
typedef enum {
    MODE_NONE,
    MODE_SELECTING,       // Marquee select
    MODE_DRAGGING,        // Moving notes
    MODE_RESIZING,        // Changing duration
    MODE_VELOCITY,        // Editing velocity
    MODE_DRAWING          // Drawing new note
} InteractionMode;

struct PianoRoll {
    GtkWidget *container;      // Main container (revealer for animation)
    GtkWidget *revealer;       // Revealer for show/hide animation
    GtkWidget *main_box;       // Horizontal box: piano + grid
    GtkWidget *piano_area;     // Piano keyboard drawing area
    GtkWidget *grid_area;      // Note grid drawing area
    GtkWidget *grid_scroll;    // Scrolled window for grid
    GtkWidget *header_bar;     // Top bar with controls
    GtkWidget *velocity_area;  // Velocity lane drawing area
    GtkWidget *snap_dropdown;  // Snap dropdown reference

    void *audio_engine;
    int track;                 // Current track being edited

    // View state
    double pixels_per_beat;
    double scroll_x;           // Horizontal scroll in beats
    int scroll_note;           // Top visible note
    bool visible;

    // Piano state
    bool keys_pressed[128];
    int hover_note;

    // Grid state
    double grid_snap;          // Snap value in beats (0.25 = 16th note)
    bool show_velocity;        // Show velocity lane

    // Interaction state
    InteractionMode mode;
    double drag_start_x;
    double drag_start_y;
    double drag_current_x;
    double drag_current_y;
    unsigned int drag_note_id; // Note being dragged/resized
    double drag_note_original_beat;
    unsigned char drag_note_original_pitch;
    double drag_note_original_duration;

    // For new note drawing
    double draw_start_beat;
    unsigned char draw_pitch;

    // Pop-out window state
    GtkWidget *popout_window;  // Pop-out window (NULL when embedded)
    GtkWidget *original_parent;  // Original parent widget to restore on pop-in
};

// Snap value to grid
static double snap_to_grid(double value, double grid) {
    if (grid <= 0) return value;
    return round(value / grid) * grid;
}

// Check if note is black key
static bool is_black_key(int note) {
    int n = note % 12;
    return (n == 1 || n == 3 || n == 6 || n == 8 || n == 10);
}

// Get Y position for a note (in grid coordinates)
static double note_to_y(PianoRoll *roll, int note) {
    return (MAX_NOTE - note - roll->scroll_note) * NOTE_HEIGHT;
}

// Get note from Y position
static int y_to_note(PianoRoll *roll, double y) {
    int note = MAX_NOTE - (int)(y / NOTE_HEIGHT) - roll->scroll_note;
    if (note < MIN_NOTE) note = MIN_NOTE;
    if (note > MAX_NOTE) note = MAX_NOTE;
    return note;
}

// Convert X position to beat
static double x_to_beat(PianoRoll *roll, double x) {
    return x / roll->pixels_per_beat + roll->scroll_x;
}

// Convert beat to X position
static double beat_to_x(PianoRoll *roll, double beat) {
    return (beat - roll->scroll_x) * roll->pixels_per_beat;
}

// Get grid snap value from dropdown index
static double get_snap_value(int index) {
    switch (index) {
        case 0: return 0.0625; // 1/64
        case 1: return 0.125;  // 1/32
        case 2: return 0.25;   // 1/16
        case 3: return 0.5;    // 1/8
        case 4: return 1.0;    // 1/4
        case 5: return 2.0;    // 1/2
        case 6: return 4.0;    // 1 Bar
        default: return 0.25;
    }
}

// Draw piano keyboard
static void draw_piano(GtkDrawingArea *area, cairo_t *cr, int width, int height, gpointer user_data) {
    (void)area;
    PianoRoll *roll = (PianoRoll *)user_data;
    if (!roll) return;

    RGB bg = hex_to_rgb(BG_DARK);
    cairo_set_source_rgb(cr, bg.r, bg.g, bg.b);
    cairo_paint(cr);

    int visible_notes = height / NOTE_HEIGHT + 1;
    int start_note = MAX_NOTE - roll->scroll_note;

    // Draw white keys first
    for (int i = 0; i < visible_notes && (start_note - i) >= MIN_NOTE; i++) {
        int note = start_note - i;
        if (is_black_key(note)) continue;

        int y = i * NOTE_HEIGHT;
        bool pressed = roll->keys_pressed[note];
        bool hover = (note == roll->hover_note);

        // Key background
        if (pressed) {
            RGB c = hex_to_rgb(BLUE);
            cairo_set_source_rgb(cr, c.r, c.g, c.b);
        } else if (hover) {
            cairo_set_source_rgb(cr, 0.85, 0.85, 0.9);
        } else {
            cairo_set_source_rgb(cr, 0.95, 0.95, 0.95);
        }
        cairo_rectangle(cr, 0, y, width - 1, NOTE_HEIGHT - 1);
        cairo_fill(cr);

        // Key border
        cairo_set_source_rgb(cr, 0.6, 0.6, 0.65);
        cairo_set_line_width(cr, 0.5);
        cairo_rectangle(cr, 0, y, width - 1, NOTE_HEIGHT - 1);
        cairo_stroke(cr);

        // Note name for C notes
        if (note % 12 == 0) {
            cairo_set_source_rgb(cr, 0.3, 0.3, 0.35);
            cairo_select_font_face(cr, "Sans", CAIRO_FONT_SLANT_NORMAL, CAIRO_FONT_WEIGHT_BOLD);
            cairo_set_font_size(cr, 9);
            char label[8];
            snprintf(label, sizeof(label), "C%d", (note / 12) - 1);
            cairo_move_to(cr, 4, y + NOTE_HEIGHT - 3);
            cairo_show_text(cr, label);
        }
    }

    // Draw black keys on top
    for (int i = 0; i < visible_notes && (start_note - i) >= MIN_NOTE; i++) {
        int note = start_note - i;
        if (!is_black_key(note)) continue;

        int y = i * NOTE_HEIGHT;
        bool pressed = roll->keys_pressed[note];
        bool hover = (note == roll->hover_note);

        // Key background
        if (pressed) {
            RGB c = hex_to_rgb(PURPLE);
            cairo_set_source_rgb(cr, c.r, c.g, c.b);
        } else if (hover) {
            cairo_set_source_rgb(cr, 0.25, 0.25, 0.3);
        } else {
            cairo_set_source_rgb(cr, 0.15, 0.15, 0.18);
        }
        cairo_rectangle(cr, 0, y, width * 0.6, NOTE_HEIGHT - 1);
        cairo_fill(cr);
    }
}

// Draw a single MIDI note
static void draw_note(cairo_t *cr, PianoRoll *roll, double start_beat, double duration,
                      int pitch, int velocity, bool selected, bool hover) {
    double x = beat_to_x(roll, start_beat);
    double y = note_to_y(roll, pitch);
    double w = duration * roll->pixels_per_beat;

    if (w < 2) w = 2;  // Minimum visible width

    // Velocity affects brightness
    double vel_factor = 0.5 + (velocity / 127.0) * 0.5;

    // Note body color based on selection
    RGB base_color;
    if (selected) {
        base_color = hex_to_rgb(ORANGE);
    } else {
        base_color = hex_to_rgb(CYAN);
    }

    // Apply velocity factor
    cairo_set_source_rgb(cr,
        base_color.r * vel_factor,
        base_color.g * vel_factor,
        base_color.b * vel_factor);

    // Draw rounded rectangle
    double radius = 3.0;
    cairo_new_path(cr);
    cairo_arc(cr, x + radius, y + radius, radius, M_PI, 1.5 * M_PI);
    cairo_arc(cr, x + w - radius, y + radius, radius, 1.5 * M_PI, 2 * M_PI);
    cairo_arc(cr, x + w - radius, y + NOTE_HEIGHT - 1 - radius, radius, 0, 0.5 * M_PI);
    cairo_arc(cr, x + radius, y + NOTE_HEIGHT - 1 - radius, radius, 0.5 * M_PI, M_PI);
    cairo_close_path(cr);
    cairo_fill(cr);

    // Border
    if (selected || hover) {
        cairo_set_source_rgb(cr, 1.0, 1.0, 1.0);
        cairo_set_line_width(cr, 1.5);
    } else {
        cairo_set_source_rgba(cr, 0.0, 0.0, 0.0, 0.3);
        cairo_set_line_width(cr, 1.0);
    }
    cairo_new_path(cr);
    cairo_arc(cr, x + radius, y + radius, radius, M_PI, 1.5 * M_PI);
    cairo_arc(cr, x + w - radius, y + radius, radius, 1.5 * M_PI, 2 * M_PI);
    cairo_arc(cr, x + w - radius, y + NOTE_HEIGHT - 1 - radius, radius, 0, 0.5 * M_PI);
    cairo_arc(cr, x + radius, y + NOTE_HEIGHT - 1 - radius, radius, 0.5 * M_PI, M_PI);
    cairo_close_path(cr);
    cairo_stroke(cr);

    // Resize handle indicator (right edge)
    if (w > 10) {
        cairo_set_source_rgba(cr, 1.0, 1.0, 1.0, 0.3);
        cairo_rectangle(cr, x + w - RESIZE_HANDLE_WIDTH, y + 2, 2, NOTE_HEIGHT - 5);
        cairo_fill(cr);
    }
}

// Draw note grid
static void draw_grid(GtkDrawingArea *area, cairo_t *cr, int width, int height, gpointer user_data) {
    (void)area;
    PianoRoll *roll = (PianoRoll *)user_data;
    if (!roll) return;

    // Background
    RGB bg = hex_to_rgb(BG_COLOR);
    cairo_set_source_rgb(cr, bg.r, bg.g, bg.b);
    cairo_paint(cr);

    int visible_notes = height / NOTE_HEIGHT + 1;
    int start_note = MAX_NOTE - roll->scroll_note;

    // Draw horizontal lines (note lanes)
    for (int i = 0; i <= visible_notes && (start_note - i) >= MIN_NOTE; i++) {
        int note = start_note - i;
        int y = i * NOTE_HEIGHT;

        // Alternate row colors
        if (is_black_key(note)) {
            RGB c = hex_to_rgb(BG_DARK);
            cairo_set_source_rgb(cr, c.r, c.g, c.b);
        } else {
            RGB c = hex_to_rgb(BG_HIGHLIGHT);
            cairo_set_source_rgba(cr, c.r, c.g, c.b, 0.3);
        }
        cairo_rectangle(cr, 0, y, width, NOTE_HEIGHT);
        cairo_fill(cr);

        // C note highlight
        if (note % 12 == 0) {
            RGB c = hex_to_rgb(COMMENT);
            cairo_set_source_rgba(cr, c.r, c.g, c.b, 0.3);
            cairo_rectangle(cr, 0, y, width, NOTE_HEIGHT);
            cairo_fill(cr);
        }

        // Row line
        cairo_set_source_rgba(cr, 0.3, 0.3, 0.35, 0.5);
        cairo_set_line_width(cr, 0.5);
        cairo_move_to(cr, 0, y);
        cairo_line_to(cr, width, y);
        cairo_stroke(cr);
    }

    // Draw vertical lines (beat grid)
    double beat_width = roll->pixels_per_beat;
    double start_beat = roll->scroll_x;
    double visible_beats = width / beat_width;

    for (double beat = floor(start_beat); beat < start_beat + visible_beats + 1; beat += 0.25) {
        double x = (beat - start_beat) * beat_width;

        // Determine line style based on beat position
        int beat_type = (int)(beat * 4) % 16;  // 16th note position in bar

        if (beat_type == 0) {  // Bar line
            RGB c = hex_to_rgb(COMMENT);
            cairo_set_source_rgba(cr, c.r, c.g, c.b, 0.9);
            cairo_set_line_width(cr, 1.5);
        } else if (beat_type % 4 == 0) {  // Beat line
            cairo_set_source_rgba(cr, 0.4, 0.4, 0.45, 0.6);
            cairo_set_line_width(cr, 1.0);
        } else {  // Sub-beat line
            cairo_set_source_rgba(cr, 0.25, 0.25, 0.3, 0.3);
            cairo_set_line_width(cr, 0.5);
        }

        cairo_move_to(cr, x, 0);
        cairo_line_to(cr, x, height);
        cairo_stroke(cr);
    }

    // Draw MIDI notes
    int note_count = midi_clip_get_note_count(roll->track);
    for (int i = 0; i < note_count; i++) {
        unsigned int id;
        double start_beat_val, duration;
        unsigned char pitch, velocity;
        int selected;

        if (midi_clip_get_note(roll->track, i, &id, &start_beat_val, &duration, &pitch, &velocity, &selected)) {
            // Check if note is visible
            double note_end = start_beat_val + duration;
            if (note_end < roll->scroll_x || start_beat_val > roll->scroll_x + visible_beats) continue;
            if (pitch < MIN_NOTE || pitch > MAX_NOTE) continue;

            bool hover = (roll->mode == MODE_DRAGGING || roll->mode == MODE_RESIZING) &&
                         roll->drag_note_id == id;
            draw_note(cr, roll, start_beat_val, duration, pitch, velocity, selected != 0, hover);
        }
    }

    // Draw selection rectangle if in selection mode
    if (roll->mode == MODE_SELECTING) {
        double x1 = fmin(roll->drag_start_x, roll->drag_current_x);
        double y1 = fmin(roll->drag_start_y, roll->drag_current_y);
        double x2 = fmax(roll->drag_start_x, roll->drag_current_x);
        double y2 = fmax(roll->drag_start_y, roll->drag_current_y);

        // Fill
        RGB c = hex_to_rgb(CYAN);
        cairo_set_source_rgba(cr, c.r, c.g, c.b, 0.15);
        cairo_rectangle(cr, x1, y1, x2 - x1, y2 - y1);
        cairo_fill(cr);

        // Border
        cairo_set_source_rgba(cr, c.r, c.g, c.b, 0.8);
        cairo_set_line_width(cr, 1.0);
        cairo_rectangle(cr, x1, y1, x2 - x1, y2 - y1);
        cairo_stroke(cr);
    }

    // Draw note being drawn
    if (roll->mode == MODE_DRAWING) {
        double current_beat = x_to_beat(roll, roll->drag_current_x);
        double duration = snap_to_grid(current_beat - roll->draw_start_beat, roll->grid_snap);
        if (duration < roll->grid_snap) duration = roll->grid_snap;

        draw_note(cr, roll, roll->draw_start_beat, duration, roll->draw_pitch, 100, true, true);
    }
}

// Check if position is on note resize handle
static bool is_on_resize_handle(PianoRoll *roll, double x, double beat, double duration) {
    double note_end_x = beat_to_x(roll, beat + duration);
    return x >= note_end_x - RESIZE_HANDLE_WIDTH && x <= note_end_x;
}

// Grid press handler
static void on_grid_pressed(GtkGestureClick *gesture, int n_press, double x, double y, gpointer user_data) {
    PianoRoll *roll = (PianoRoll *)user_data;
    if (!roll) return;

    guint button = gtk_gesture_single_get_current_button(GTK_GESTURE_SINGLE(gesture));
    GdkModifierType state = gtk_event_controller_get_current_event_state(GTK_EVENT_CONTROLLER(gesture));
    bool shift = (state & GDK_SHIFT_MASK) != 0;
    bool ctrl = (state & GDK_CONTROL_MASK) != 0;

    double beat = x_to_beat(roll, x);
    int pitch = y_to_note(roll, y);

    roll->drag_start_x = x;
    roll->drag_start_y = y;
    roll->drag_current_x = x;
    roll->drag_current_y = y;

    if (button == GDK_BUTTON_PRIMARY) {
        // Check if clicking on a note
        unsigned int note_id = midi_clip_find_note_at(roll->track, beat, (unsigned char)pitch);

        if (note_id > 0) {
            // Get note info for drag by finding the note with matching id
            unsigned int id = 0;
            double start_beat = 0, duration = 0;
            unsigned char note_pitch = 0, velocity = 0;
            int selected = 0;

            int count = midi_clip_get_note_count(roll->track);
            for (int i = 0; i < count; i++) {
                if (midi_clip_get_note(roll->track, i, &id, &start_beat, &duration, &note_pitch, &velocity, &selected)) {
                    if (id == note_id) break;
                }
            }

            roll->drag_note_id = note_id;
            roll->drag_note_original_beat = start_beat;
            roll->drag_note_original_pitch = note_pitch;
            roll->drag_note_original_duration = duration;

            if (is_on_resize_handle(roll, x, start_beat, duration)) {
                // Resize mode
                roll->mode = MODE_RESIZING;
            } else {
                // Drag mode
                if (!shift && !selected) {
                    // Deselect others if not shift-clicking
                    midi_clip_deselect_all(roll->track);
                }
                midi_clip_set_selected(roll->track, note_id, 1);
                roll->mode = MODE_DRAGGING;
            }
        } else if (n_press == 2) {
            // Double-click: create new note
            double snapped_beat = snap_to_grid(beat, roll->grid_snap);
            roll->draw_start_beat = snapped_beat;
            roll->draw_pitch = (unsigned char)pitch;
            roll->mode = MODE_DRAWING;
        } else {
            // Click on empty space: start marquee selection
            if (!shift) {
                midi_clip_deselect_all(roll->track);
            }
            roll->mode = MODE_SELECTING;
        }
    } else if (button == GDK_BUTTON_SECONDARY) {
        // Right-click: delete note or show menu
        unsigned int note_id = midi_clip_find_note_at(roll->track, beat, (unsigned char)pitch);
        if (note_id > 0) {
            midi_clip_remove_note(roll->track, note_id);
        }
    }

    (void)ctrl;
    gtk_widget_queue_draw(roll->grid_area);
}

// Grid drag handler
static void on_grid_drag(GtkGestureDrag *gesture, double offset_x, double offset_y, gpointer user_data) {
    (void)gesture;
    PianoRoll *roll = (PianoRoll *)user_data;
    if (!roll) return;

    roll->drag_current_x = roll->drag_start_x + offset_x;
    roll->drag_current_y = roll->drag_start_y + offset_y;

    if (roll->mode == MODE_DRAGGING) {
        // Move selected notes
        double delta_beat = x_to_beat(roll, roll->drag_current_x) - x_to_beat(roll, roll->drag_start_x);
        int delta_pitch = y_to_note(roll, roll->drag_current_y) - y_to_note(roll, roll->drag_start_y);

        // Snap delta to grid
        delta_beat = snap_to_grid(delta_beat, roll->grid_snap);

        // Calculate new position for the dragged note
        double new_beat = roll->drag_note_original_beat + delta_beat;
        int new_pitch = (int)roll->drag_note_original_pitch + delta_pitch;

        if (new_beat >= 0 && new_pitch >= MIN_NOTE && new_pitch <= MAX_NOTE) {
            // Move the primary dragged note
            midi_clip_move_note(roll->track, roll->drag_note_id, new_beat, (unsigned char)new_pitch);

            // Move other selected notes by the same delta
            // (This is handled by updating the primary note; for multi-note drag we'd use move_selected)
        }
    } else if (roll->mode == MODE_RESIZING) {
        // Resize note
        double current_beat = x_to_beat(roll, roll->drag_current_x);
        double new_duration = current_beat - roll->drag_note_original_beat;
        new_duration = snap_to_grid(new_duration, roll->grid_snap);
        if (new_duration < roll->grid_snap) new_duration = roll->grid_snap;

        midi_clip_resize_note(roll->track, roll->drag_note_id, new_duration);
    }

    gtk_widget_queue_draw(roll->grid_area);
}

// Grid release handler
static void on_grid_released(GtkGestureClick *gesture, int n_press, double x, double y, gpointer user_data) {
    (void)gesture;
    (void)n_press;
    (void)x;
    (void)y;
    PianoRoll *roll = (PianoRoll *)user_data;
    if (!roll) return;

    if (roll->mode == MODE_SELECTING) {
        // Finalize marquee selection
        double beat_start = x_to_beat(roll, fmin(roll->drag_start_x, roll->drag_current_x));
        double beat_end = x_to_beat(roll, fmax(roll->drag_start_x, roll->drag_current_x));
        int pitch_low = y_to_note(roll, fmax(roll->drag_start_y, roll->drag_current_y));
        int pitch_high = y_to_note(roll, fmin(roll->drag_start_y, roll->drag_current_y));

        GdkModifierType state = gtk_event_controller_get_current_event_state(GTK_EVENT_CONTROLLER(gesture));
        bool shift = (state & GDK_SHIFT_MASK) != 0;

        midi_clip_select_in_rect(roll->track, beat_start, beat_end,
            (unsigned char)pitch_low, (unsigned char)pitch_high, shift ? 1 : 0);
    } else if (roll->mode == MODE_DRAWING) {
        // Finalize new note
        double current_beat = x_to_beat(roll, roll->drag_current_x);
        double duration = snap_to_grid(current_beat - roll->draw_start_beat, roll->grid_snap);
        if (duration < roll->grid_snap) duration = roll->grid_snap;

        midi_clip_add_note(roll->track, roll->draw_start_beat, duration, roll->draw_pitch, 100);
    }

    roll->mode = MODE_NONE;
    roll->drag_note_id = 0;
    gtk_widget_queue_draw(roll->grid_area);
}

// Grid motion handler (for cursor changes)
static void on_grid_motion(GtkEventControllerMotion *controller, double x, double y, gpointer user_data) {
    (void)controller;
    PianoRoll *roll = (PianoRoll *)user_data;
    if (!roll) return;

    double beat = x_to_beat(roll, x);
    int pitch = y_to_note(roll, y);

    // Check for note under cursor
    unsigned int note_id = midi_clip_find_note_at(roll->track, beat, (unsigned char)pitch);

    if (note_id > 0) {
        // Get note info
        int count = midi_clip_get_note_count(roll->track);
        for (int i = 0; i < count; i++) {
            unsigned int id;
            double start_beat, duration;
            unsigned char note_pitch, velocity;
            int selected;

            if (midi_clip_get_note(roll->track, i, &id, &start_beat, &duration, &note_pitch, &velocity, &selected)) {
                if (id == note_id) {
                    if (is_on_resize_handle(roll, x, start_beat, duration)) {
                        gtk_widget_set_cursor_from_name(roll->grid_area, "ew-resize");
                    } else {
                        gtk_widget_set_cursor_from_name(roll->grid_area, "grab");
                    }
                    return;
                }
            }
        }
    }

    gtk_widget_set_cursor_from_name(roll->grid_area, "crosshair");
}

// Piano key press
static void on_piano_pressed(GtkGestureClick *gesture, int n_press, double x, double y, gpointer user_data) {
    (void)gesture;
    (void)n_press;
    (void)x;
    PianoRoll *roll = (PianoRoll *)user_data;
    if (!roll) return;

    int note = y_to_note(roll, y);
    if (note >= MIN_NOTE && note <= MAX_NOTE) {
        roll->keys_pressed[note] = true;

        // Start audio if not playing
        if (roll->audio_engine && !audio_engine_is_playing(roll->audio_engine)) {
            audio_engine_start(roll->audio_engine);
        }

        audio_engine_note_on(roll->audio_engine, roll->track, note, 100);
        gtk_widget_queue_draw(roll->piano_area);
    }
}

// Piano key release
static void on_piano_released(GtkGestureClick *gesture, int n_press, double x, double y, gpointer user_data) {
    (void)gesture;
    (void)n_press;
    (void)x;
    (void)y;
    PianoRoll *roll = (PianoRoll *)user_data;
    if (!roll) return;

    // Release all pressed keys
    for (int i = 0; i < 128; i++) {
        if (roll->keys_pressed[i]) {
            roll->keys_pressed[i] = false;
            audio_engine_note_off(roll->audio_engine, roll->track, i);
        }
    }
    gtk_widget_queue_draw(roll->piano_area);
}

// Piano motion for hover
static void on_piano_motion(GtkEventControllerMotion *controller, double x, double y, gpointer user_data) {
    (void)controller;
    (void)x;
    PianoRoll *roll = (PianoRoll *)user_data;
    if (!roll) return;

    int note = y_to_note(roll, y);
    if (note != roll->hover_note) {
        roll->hover_note = note;
        gtk_widget_queue_draw(roll->piano_area);
    }
}

// Scroll handler for grid
static gboolean on_scroll(GtkEventControllerScroll *controller, double dx, double dy, gpointer user_data) {
    (void)controller;
    (void)dx;
    PianoRoll *roll = (PianoRoll *)user_data;
    if (!roll) return FALSE;

    // Vertical scroll changes visible notes
    roll->scroll_note += (int)(dy * 3);
    if (roll->scroll_note < 0) roll->scroll_note = 0;
    if (roll->scroll_note > MAX_NOTE - MIN_NOTE - 10) roll->scroll_note = MAX_NOTE - MIN_NOTE - 10;

    gtk_widget_queue_draw(roll->piano_area);
    gtk_widget_queue_draw(roll->grid_area);

    return TRUE;
}

// QWERTY keyboard to MIDI note
static int qwerty_to_note(guint keyval, int octave_offset) {
    int base = 60 + octave_offset * 12;  // Middle C + offset

    switch (keyval) {
        // Lower row: Z-M = C-B
        case GDK_KEY_z: case GDK_KEY_Z: return base;
        case GDK_KEY_s: case GDK_KEY_S: return base + 1;
        case GDK_KEY_x: case GDK_KEY_X: return base + 2;
        case GDK_KEY_d: case GDK_KEY_D: return base + 3;
        case GDK_KEY_c: case GDK_KEY_C: return base + 4;
        case GDK_KEY_v: case GDK_KEY_V: return base + 5;
        case GDK_KEY_g: case GDK_KEY_G: return base + 6;
        case GDK_KEY_b: case GDK_KEY_B: return base + 7;
        case GDK_KEY_h: case GDK_KEY_H: return base + 8;
        case GDK_KEY_n: case GDK_KEY_N: return base + 9;
        case GDK_KEY_j: case GDK_KEY_J: return base + 10;
        case GDK_KEY_m: case GDK_KEY_M: return base + 11;

        // Upper row: Q-] = C-B (octave up)
        case GDK_KEY_q: case GDK_KEY_Q: return base + 12;
        case GDK_KEY_2: return base + 13;
        case GDK_KEY_w: case GDK_KEY_W: return base + 14;
        case GDK_KEY_3: return base + 15;
        case GDK_KEY_e: case GDK_KEY_E: return base + 16;
        case GDK_KEY_r: case GDK_KEY_R: return base + 17;
        case GDK_KEY_5: return base + 18;
        case GDK_KEY_t: case GDK_KEY_T: return base + 19;
        case GDK_KEY_6: return base + 20;
        case GDK_KEY_y: case GDK_KEY_Y: return base + 21;
        case GDK_KEY_7: return base + 22;
        case GDK_KEY_u: case GDK_KEY_U: return base + 23;
        case GDK_KEY_i: case GDK_KEY_I: return base + 24;

        default: return -1;
    }
}

// Keyboard press
static gboolean on_key_pressed(GtkEventControllerKey *controller, guint keyval, guint keycode, GdkModifierType state, gpointer user_data) {
    (void)controller;
    (void)keycode;
    PianoRoll *roll = (PianoRoll *)user_data;
    if (!roll) return FALSE;

    // Escape - close/hide piano roll
    if (keyval == GDK_KEY_Escape) {
        if (roll->popout_window) {
            gtk_window_close(GTK_WINDOW(roll->popout_window));
        } else {
            piano_roll_hide(roll);
        }
        return TRUE;
    }

    // Delete selected notes
    if (keyval == GDK_KEY_Delete || keyval == GDK_KEY_BackSpace) {
        int deleted = midi_clip_delete_selected(roll->track);
        if (deleted > 0) {
            gtk_widget_queue_draw(roll->grid_area);
            return TRUE;
        }
    }

    // Select all (Ctrl+A)
    if (keyval == GDK_KEY_a && (state & GDK_CONTROL_MASK)) {
        midi_clip_select_all(roll->track);
        gtk_widget_queue_draw(roll->grid_area);
        return TRUE;
    }

    // Quantize selected (Q)
    if (keyval == GDK_KEY_q && !(state & GDK_CONTROL_MASK)) {
        // Don't quantize if shift is held (that's for keyboard playing)
        if (!(state & GDK_SHIFT_MASK)) {
            midi_clip_quantize_selected(roll->track, roll->grid_snap);
            gtk_widget_queue_draw(roll->grid_area);
            return TRUE;
        }
    }

    // QWERTY keyboard playing
    int note = qwerty_to_note(keyval, -1);  // Start at C3
    if (note >= 0 && note < 128 && !roll->keys_pressed[note]) {
        roll->keys_pressed[note] = true;

        if (roll->audio_engine && !audio_engine_is_playing(roll->audio_engine)) {
            audio_engine_start(roll->audio_engine);
        }

        audio_engine_note_on(roll->audio_engine, roll->track, note, 100);
        gtk_widget_queue_draw(roll->piano_area);
        return TRUE;
    }

    return FALSE;
}

// Keyboard release
static void on_key_released(GtkEventControllerKey *controller, guint keyval, guint keycode, GdkModifierType state, gpointer user_data) {
    (void)controller;
    (void)keycode;
    (void)state;
    PianoRoll *roll = (PianoRoll *)user_data;
    if (!roll) return;

    int note = qwerty_to_note(keyval, -1);
    if (note >= 0 && note < 128 && roll->keys_pressed[note]) {
        roll->keys_pressed[note] = false;
        audio_engine_note_off(roll->audio_engine, roll->track, note);
        gtk_widget_queue_draw(roll->piano_area);
    }
}

// Snap dropdown changed
static void on_snap_changed(GObject *dropdown, GParamSpec *pspec, gpointer user_data) {
    (void)pspec;
    PianoRoll *roll = (PianoRoll *)user_data;
    if (!roll) return;

    guint selected = gtk_drop_down_get_selected(GTK_DROP_DOWN(dropdown));
    roll->grid_snap = get_snap_value(selected);
    gtk_widget_queue_draw(roll->grid_area);
}

// Quantize button clicked
static void on_quantize_clicked(GtkButton *button, gpointer user_data) {
    (void)button;
    PianoRoll *roll = (PianoRoll *)user_data;
    if (!roll) return;

    midi_clip_quantize_selected(roll->track, roll->grid_snap);
    gtk_widget_queue_draw(roll->grid_area);
}

// Close button clicked - hide the piano roll
static void on_close_clicked(GtkButton *button, gpointer user_data) {
    (void)button;
    PianoRoll *roll = (PianoRoll *)user_data;
    if (!roll) return;

    // If in pop-out mode, close the window (which will hide back to normal)
    if (roll->popout_window) {
        gtk_window_close(GTK_WINDOW(roll->popout_window));
    } else {
        // Hide the embedded piano roll
        piano_roll_hide(roll);
    }
}

// Pop-out window closed - return to embedded mode
static gboolean on_popout_close_request(GtkWindow *window, gpointer user_data) {
    PianoRoll *roll = (PianoRoll *)user_data;
    if (!roll) return FALSE;

    // Reparent the container back to the original parent
    if (roll->original_parent) {
        g_object_ref(roll->container);  // Keep reference during reparent
        gtk_window_set_child(GTK_WINDOW(window), NULL);

        // Re-add to revealer
        gtk_revealer_set_child(GTK_REVEALER(roll->revealer), roll->container);
        g_object_unref(roll->container);

        // Hide the piano roll (back to embedded mode)
        roll->popout_window = NULL;
        roll->visible = false;
        gtk_revealer_set_reveal_child(GTK_REVEALER(roll->revealer), FALSE);
        printf("🎹 Piano roll returned to embedded mode\n");
    }

    return FALSE;  // Allow the window to close
}

// Pop-out button clicked - detach to separate window
static void on_popout_clicked(GtkButton *button, gpointer user_data) {
    (void)button;
    PianoRoll *roll = (PianoRoll *)user_data;
    if (!roll) return;

    // Already in pop-out mode? Do nothing
    if (roll->popout_window) {
        gtk_window_present(GTK_WINDOW(roll->popout_window));
        return;
    }

    // Store original parent
    roll->original_parent = gtk_widget_get_parent(roll->revealer);

    // Create pop-out window
    roll->popout_window = gtk_window_new();
    gtk_window_set_title(GTK_WINDOW(roll->popout_window), "Piano Roll");
    gtk_window_set_default_size(GTK_WINDOW(roll->popout_window), 800, 400);
    gtk_window_set_resizable(GTK_WINDOW(roll->popout_window), TRUE);

    // Reparent the container to the new window
    g_object_ref(roll->container);  // Keep reference during reparent
    gtk_revealer_set_child(GTK_REVEALER(roll->revealer), NULL);
    gtk_window_set_child(GTK_WINDOW(roll->popout_window), roll->container);
    g_object_unref(roll->container);

    // Connect close request to return to embedded mode
    g_signal_connect(roll->popout_window, "close-request", G_CALLBACK(on_popout_close_request), roll);

    // Show the window
    gtk_window_present(GTK_WINDOW(roll->popout_window));

    // Hide the revealer since content moved to pop-out
    gtk_revealer_set_reveal_child(GTK_REVEALER(roll->revealer), FALSE);

    printf("🎹 Piano roll popped out to window\n");
}

// Create header bar with track info and controls
static GtkWidget* create_header_bar(PianoRoll *roll) {
    GtkWidget *box = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8);
    gtk_widget_set_margin_start(box, 8);
    gtk_widget_set_margin_end(box, 8);
    gtk_widget_set_margin_top(box, 4);
    gtk_widget_set_margin_bottom(box, 4);

    // Apply dark background
    GtkCssProvider *css = gtk_css_provider_new();
    gtk_css_provider_load_from_string(css,
        "box { background-color: #16161e; border-bottom: 1px solid #292e42; }");
    gtk_style_context_add_provider(
        gtk_widget_get_style_context(box),
        GTK_STYLE_PROVIDER(css),
        GTK_STYLE_PROVIDER_PRIORITY_APPLICATION);
    g_object_unref(css);

    // Track label
    GtkWidget *track_label = gtk_label_new(NULL);
    char markup[128];
    snprintf(markup, sizeof(markup),
        "<span foreground='#7aa2f7' weight='bold'>Piano Roll</span> "
        "<span foreground='#565f89'>Track %d</span>",
        roll->track + 1);
    gtk_label_set_markup(GTK_LABEL(track_label), markup);
    gtk_box_append(GTK_BOX(box), track_label);

    // Spacer
    GtkWidget *spacer = gtk_label_new("");
    gtk_widget_set_hexpand(spacer, TRUE);
    gtk_box_append(GTK_BOX(box), spacer);

    // Quantize button
    GtkWidget *quantize_btn = gtk_button_new_with_label("Q");
    gtk_widget_set_tooltip_text(quantize_btn, "Quantize selected notes (Q)");
    g_signal_connect(quantize_btn, "clicked", G_CALLBACK(on_quantize_clicked), roll);
    gtk_box_append(GTK_BOX(box), quantize_btn);

    // Snap dropdown
    GtkWidget *snap_label = gtk_label_new(NULL);
    gtk_label_set_markup(GTK_LABEL(snap_label), "<span foreground='#565f89'>Snap:</span>");
    gtk_box_append(GTK_BOX(box), snap_label);

    const char *snap_options[] = { "1/64", "1/32", "1/16", "1/8", "1/4", "1/2", "1 Bar", NULL };
    roll->snap_dropdown = gtk_drop_down_new_from_strings(snap_options);
    gtk_drop_down_set_selected(GTK_DROP_DOWN(roll->snap_dropdown), 2);  // Default 1/16
    g_signal_connect(roll->snap_dropdown, "notify::selected", G_CALLBACK(on_snap_changed), roll);
    gtk_box_append(GTK_BOX(box), roll->snap_dropdown);

    // Help text
    GtkWidget *help = gtk_label_new(NULL);
    gtk_label_set_markup(GTK_LABEL(help),
        "<span foreground='#565f89' size='small'>Double-click: add | Right-click: delete | Del: remove selected</span>");
    gtk_box_append(GTK_BOX(box), help);

    // Pop-out button
    GtkWidget *popout_btn = gtk_button_new_with_label("⧉");
    gtk_widget_set_tooltip_text(popout_btn, "Pop out to window");
    g_signal_connect(popout_btn, "clicked", G_CALLBACK(on_popout_clicked), roll);
    gtk_box_append(GTK_BOX(box), popout_btn);

    // Close button
    GtkWidget *close_btn = gtk_button_new_with_label("✕");
    gtk_widget_set_tooltip_text(close_btn, "Close piano roll (Esc)");
    g_signal_connect(close_btn, "clicked", G_CALLBACK(on_close_clicked), roll);
    gtk_box_append(GTK_BOX(box), close_btn);

    return box;
}

PianoRoll* piano_roll_new(void *audio_engine) {
    PianoRoll *roll = malloc(sizeof(PianoRoll));
    if (!roll) return NULL;

    memset(roll, 0, sizeof(PianoRoll));
    roll->audio_engine = audio_engine;
    roll->track = 0;
    roll->pixels_per_beat = DEFAULT_PIXELS_PER_BEAT;
    roll->scroll_note = 36;  // Start at C3 area
    roll->hover_note = -1;
    roll->grid_snap = 0.25;  // 16th note
    roll->visible = false;
    roll->mode = MODE_NONE;

    // Create revealer for animation
    roll->revealer = gtk_revealer_new();
    gtk_revealer_set_transition_type(GTK_REVEALER(roll->revealer), GTK_REVEALER_TRANSITION_TYPE_SLIDE_UP);
    gtk_revealer_set_transition_duration(GTK_REVEALER(roll->revealer), 200);
    gtk_revealer_set_reveal_child(GTK_REVEALER(roll->revealer), FALSE);

    // Main container
    roll->container = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0);
    gtk_widget_set_size_request(roll->container, -1, PIANO_ROLL_HEIGHT);
    gtk_revealer_set_child(GTK_REVEALER(roll->revealer), roll->container);

    // Header bar
    roll->header_bar = create_header_bar(roll);
    gtk_box_append(GTK_BOX(roll->container), roll->header_bar);

    // Main content: piano + grid
    roll->main_box = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 0);
    gtk_widget_set_vexpand(roll->main_box, TRUE);
    gtk_box_append(GTK_BOX(roll->container), roll->main_box);

    // Piano area
    roll->piano_area = gtk_drawing_area_new();
    gtk_widget_set_size_request(roll->piano_area, PIANO_KEY_WIDTH, -1);
    gtk_drawing_area_set_draw_func(GTK_DRAWING_AREA(roll->piano_area), draw_piano, roll, NULL);

    // Piano mouse handlers
    GtkGesture *piano_click = gtk_gesture_click_new();
    gtk_gesture_single_set_button(GTK_GESTURE_SINGLE(piano_click), GDK_BUTTON_PRIMARY);
    g_signal_connect(piano_click, "pressed", G_CALLBACK(on_piano_pressed), roll);
    g_signal_connect(piano_click, "released", G_CALLBACK(on_piano_released), roll);
    gtk_widget_add_controller(roll->piano_area, GTK_EVENT_CONTROLLER(piano_click));

    GtkEventController *piano_motion = gtk_event_controller_motion_new();
    g_signal_connect(piano_motion, "motion", G_CALLBACK(on_piano_motion), roll);
    gtk_widget_add_controller(roll->piano_area, piano_motion);

    gtk_box_append(GTK_BOX(roll->main_box), roll->piano_area);

    // Separator
    GtkWidget *sep = gtk_separator_new(GTK_ORIENTATION_VERTICAL);
    gtk_box_append(GTK_BOX(roll->main_box), sep);

    // Grid scrolled area
    roll->grid_scroll = gtk_scrolled_window_new();
    gtk_scrolled_window_set_policy(GTK_SCROLLED_WINDOW(roll->grid_scroll),
        GTK_POLICY_AUTOMATIC, GTK_POLICY_EXTERNAL);  // Sync vertical scroll with piano
    gtk_widget_set_hexpand(roll->grid_scroll, TRUE);

    roll->grid_area = gtk_drawing_area_new();
    gtk_widget_set_size_request(roll->grid_area, 2000, (MAX_NOTE - MIN_NOTE + 1) * NOTE_HEIGHT);
    gtk_drawing_area_set_draw_func(GTK_DRAWING_AREA(roll->grid_area), draw_grid, roll, NULL);

    // Grid mouse handlers
    GtkGesture *grid_click = gtk_gesture_click_new();
    gtk_gesture_single_set_button(GTK_GESTURE_SINGLE(grid_click), 0);  // All buttons
    g_signal_connect(grid_click, "pressed", G_CALLBACK(on_grid_pressed), roll);
    g_signal_connect(grid_click, "released", G_CALLBACK(on_grid_released), roll);
    gtk_widget_add_controller(roll->grid_area, GTK_EVENT_CONTROLLER(grid_click));

    GtkGesture *grid_drag = gtk_gesture_drag_new();
    g_signal_connect(grid_drag, "drag-update", G_CALLBACK(on_grid_drag), roll);
    gtk_widget_add_controller(roll->grid_area, GTK_EVENT_CONTROLLER(grid_drag));

    GtkEventController *grid_motion = gtk_event_controller_motion_new();
    g_signal_connect(grid_motion, "motion", G_CALLBACK(on_grid_motion), roll);
    gtk_widget_add_controller(roll->grid_area, grid_motion);

    gtk_scrolled_window_set_child(GTK_SCROLLED_WINDOW(roll->grid_scroll), roll->grid_area);
    gtk_box_append(GTK_BOX(roll->main_box), roll->grid_scroll);

    // Scroll controller (for vertical scroll on both piano and grid)
    GtkEventController *scroll = gtk_event_controller_scroll_new(
        GTK_EVENT_CONTROLLER_SCROLL_VERTICAL | GTK_EVENT_CONTROLLER_SCROLL_DISCRETE);
    g_signal_connect(scroll, "scroll", G_CALLBACK(on_scroll), roll);
    gtk_widget_add_controller(roll->main_box, scroll);

    // Keyboard controller
    GtkEventController *key = gtk_event_controller_key_new();
    g_signal_connect(key, "key-pressed", G_CALLBACK(on_key_pressed), roll);
    g_signal_connect(key, "key-released", G_CALLBACK(on_key_released), roll);
    gtk_widget_add_controller(roll->container, key);

    // Make focusable for keyboard input
    gtk_widget_set_focusable(roll->container, TRUE);
    gtk_widget_set_can_focus(roll->container, TRUE);

    printf("Piano roll created with MIDI editing\n");

    return roll;
}

GtkWidget* piano_roll_get_widget(PianoRoll *roll) {
    return roll ? roll->revealer : NULL;
}

void piano_roll_set_track(PianoRoll *roll, int track) {
    if (!roll) return;
    roll->track = track;

    // Update header
    if (roll->header_bar) {
        GtkWidget *child = gtk_widget_get_first_child(roll->header_bar);
        if (child && GTK_IS_LABEL(child)) {
            char markup[128];
            snprintf(markup, sizeof(markup),
                "<span foreground='#7aa2f7' weight='bold'>Piano Roll</span> "
                "<span foreground='#565f89'>Track %d</span>",
                track + 1);
            gtk_label_set_markup(GTK_LABEL(child), markup);
        }
    }

    gtk_widget_queue_draw(roll->piano_area);
    gtk_widget_queue_draw(roll->grid_area);
}

int piano_roll_get_track(PianoRoll *roll) {
    return roll ? roll->track : -1;
}

void piano_roll_show(PianoRoll *roll) {
    if (!roll) return;
    roll->visible = true;

    // Add demo notes if the track is empty (first time showing)
    if (!midi_clip_has_notes(roll->track)) {
        midi_clip_add_demo_notes(roll->track);
        printf("Added demo MIDI notes to track %d\n", roll->track + 1);
    }

    gtk_revealer_set_reveal_child(GTK_REVEALER(roll->revealer), TRUE);
    gtk_widget_grab_focus(roll->container);
    printf("Piano roll shown for track %d\n", roll->track + 1);
}

void piano_roll_hide(PianoRoll *roll) {
    if (!roll) return;
    roll->visible = false;
    gtk_revealer_set_reveal_child(GTK_REVEALER(roll->revealer), FALSE);

    // Release any held notes
    for (int i = 0; i < 128; i++) {
        if (roll->keys_pressed[i]) {
            roll->keys_pressed[i] = false;
            audio_engine_note_off(roll->audio_engine, roll->track, i);
        }
    }
    printf("Piano roll hidden\n");
}

bool piano_roll_is_visible(PianoRoll *roll) {
    return roll ? roll->visible : false;
}

void piano_roll_toggle(PianoRoll *roll) {
    if (!roll) return;
    if (roll->visible) {
        piano_roll_hide(roll);
    } else {
        piano_roll_show(roll);
    }
}

void piano_roll_set_zoom(PianoRoll *roll, double pixels_per_beat) {
    if (!roll) return;
    roll->pixels_per_beat = pixels_per_beat;
    gtk_widget_queue_draw(roll->grid_area);
}

void piano_roll_scroll_to(PianoRoll *roll, double beat) {
    if (!roll) return;
    roll->scroll_x = beat;
    gtk_widget_queue_draw(roll->grid_area);
}

void piano_roll_destroy(PianoRoll *roll) {
    if (!roll) return;

    // Release all notes
    for (int i = 0; i < 128; i++) {
        if (roll->keys_pressed[i]) {
            audio_engine_note_off(roll->audio_engine, roll->track, i);
        }
    }

    free(roll);
    printf("Piano roll destroyed\n");
}
