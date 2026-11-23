#ifndef INSTRUMENT_MODAL_GTK_H
#define INSTRUMENT_MODAL_GTK_H

#include <gtk/gtk.h>
#include <stdbool.h>
#include <stdint.h>

typedef struct InstrumentModal InstrumentModal;

// Instrument control functions (from Zig audio engine C API)
extern int audio_engine_get_instrument_type_count(void);
extern const char* audio_engine_get_instrument_type_name(int index);
extern int audio_engine_set_track_instrument(void *engine, int track, int instrument_type);
extern void audio_engine_remove_track_instrument(void *engine, int track);
extern int audio_engine_track_has_instrument(void *engine, int track);
extern const char* audio_engine_get_track_instrument_name(void *engine, int track);
extern void audio_engine_note_on(void *engine, int track, int note, int velocity);
extern void audio_engine_note_off(void *engine, int track, int note);
extern void audio_engine_all_notes_off(void *engine, int track);
extern int audio_engine_start(void *engine);
extern int audio_engine_is_playing(void *engine);

// Instrument parameter functions
extern int audio_engine_get_track_instrument_param_count(void *engine, int track);
extern const char* audio_engine_get_track_instrument_param_name(void *engine, int track, int param);
extern float audio_engine_get_track_instrument_param_value(void *engine, int track, int param);
extern float audio_engine_get_track_instrument_param_min(void *engine, int track, int param);
extern float audio_engine_get_track_instrument_param_max(void *engine, int track, int param);
extern const char* audio_engine_get_track_instrument_param_unit(void *engine, int track, int param);
extern void audio_engine_set_track_instrument_param(void *engine, int track, int param, float value);

// MIDI helpers
extern int midi_is_black_key(int note);

// Scale/Key lock functions (from Zig scale C API)
extern int scale_get_count(void);
extern const char* scale_get_name(int index);
extern int scale_get_root_count(void);
extern const char* scale_get_root_name(int index);
extern int scale_contains_note(int scale_type, int root_note, int midi_note);
extern int scale_quantize_note(int scale_type, int root_note, int midi_note);
extern int scale_get_degree_count(int scale_type);
extern int scale_degree_to_midi(int scale_type, int root_note, int degree, int octave);

// Modal lifecycle
InstrumentModal* instrument_modal_new(GtkWindow *parent, void *audio_engine, int track);
void instrument_modal_show(InstrumentModal *modal);
void instrument_modal_hide(InstrumentModal *modal);
void instrument_modal_destroy(InstrumentModal *modal);

// Update instrument display
void instrument_modal_refresh(InstrumentModal *modal);

#endif // INSTRUMENT_MODAL_GTK_H
