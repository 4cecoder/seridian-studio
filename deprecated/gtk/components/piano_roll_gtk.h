#ifndef PIANO_ROLL_GTK_H
#define PIANO_ROLL_GTK_H

#include <gtk/gtk.h>
#include <stdbool.h>
#include <stdint.h>

typedef struct PianoRoll PianoRoll;

// Audio engine functions (from Zig)
extern void audio_engine_note_on(void *engine, int track, int note, int velocity);
extern void audio_engine_note_off(void *engine, int track, int note);
extern int audio_engine_track_has_instrument(void *engine, int track);
extern int audio_engine_start(void *engine);
extern int audio_engine_is_playing(void *engine);

// Create piano roll panel
PianoRoll* piano_roll_new(void *audio_engine);

// Get the widget to add to container
GtkWidget* piano_roll_get_widget(PianoRoll *roll);

// Set the active track for editing
void piano_roll_set_track(PianoRoll *roll, int track);

// Get current track
int piano_roll_get_track(PianoRoll *roll);

// Show/hide the piano roll
void piano_roll_show(PianoRoll *roll);
void piano_roll_hide(PianoRoll *roll);
bool piano_roll_is_visible(PianoRoll *roll);

// Toggle visibility
void piano_roll_toggle(PianoRoll *roll);

// Set zoom level (pixels per beat)
void piano_roll_set_zoom(PianoRoll *roll, double pixels_per_beat);

// Scroll to position (in beats)
void piano_roll_scroll_to(PianoRoll *roll, double beat);

// Cleanup
void piano_roll_destroy(PianoRoll *roll);

#endif // PIANO_ROLL_GTK_H
