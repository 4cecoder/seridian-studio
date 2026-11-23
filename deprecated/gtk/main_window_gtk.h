#ifndef MAIN_WINDOW_GTK_H
#define MAIN_WINDOW_GTK_H

#include <gtk/gtk.h>

typedef struct MainWindow MainWindow;
typedef struct LibraryPanel LibraryPanel;

// Theme initialization (call before creating windows)
void daw_load_theme(void);

// Window lifecycle
MainWindow* main_window_new(GMainLoop *loop, void *audio_engine);
void main_window_show(MainWindow *win);
void main_window_destroy(MainWindow *win);

// Transport updates
void main_window_update_transport(MainWindow *win, gboolean playing, gdouble position);

// Meter updates
void main_window_update_meters(MainWindow *win, const float *levels, int count);

// Status bar
void main_window_set_status(MainWindow *win, const char *message);

// Audio engine wrapper functions (call into Zig)
int audio_engine_start(void *engine);
void audio_engine_stop(void *engine);
int audio_engine_is_playing(void *engine);
void audio_engine_set_position(void *engine, uint64_t position);
uint64_t audio_engine_get_position(void *engine);
void audio_engine_set_tempo(void *engine, float bpm);
float audio_engine_get_tempo(void *engine);
void audio_engine_set_track_gain(void *engine, int track, float gain);
void audio_engine_set_master_gain(void *engine, float gain);
void audio_engine_set_track_mute(void *engine, int track, int muted);
void audio_engine_set_track_solo(void *engine, int track, int soloed);
int audio_engine_get_track_mute(void *engine, int track);
int audio_engine_get_track_solo(void *engine, int track);
void audio_engine_set_track_arm(void *engine, int track, int armed);
int audio_engine_get_track_arm(void *engine, int track);
float audio_engine_get_track_meter(void *engine, int track);
float audio_engine_get_master_meter_left(void *engine);
float audio_engine_get_master_meter_right(void *engine);

// Instrument functions
int audio_engine_get_instrument_type_count(void);
const char* audio_engine_get_instrument_type_name(int index);
int audio_engine_set_track_instrument(void *engine, int track, int instrument_type);
void audio_engine_remove_track_instrument(void *engine, int track);
int audio_engine_track_has_instrument(void *engine, int track);
const char* audio_engine_get_track_instrument_name(void *engine, int track);
void audio_engine_note_on(void *engine, int track, int note, int velocity);
void audio_engine_note_off(void *engine, int track, int note);

// Pan control
void audio_engine_set_track_pan(void *engine, int track, float pan);
float audio_engine_get_track_pan(void *engine, int track);

// Clip management functions
int track_get_clip_count(void *engine, int track);
uint64_t track_get_clip_id(void *engine, int track, int clip_idx);
double track_get_clip_start(void *engine, int track, uint64_t clip_id);
double track_get_clip_duration(void *engine, int track, uint64_t clip_id);
uint32_t track_get_clip_color(void *engine, int track, uint64_t clip_id);
const char* track_get_clip_name(void *engine, int track, uint64_t clip_id);
int track_get_clip_muted(void *engine, int track, uint64_t clip_id);
int track_set_clip_position(void *engine, int track, uint64_t clip_id, double start_time);
int track_set_clip_duration(void *engine, int track, uint64_t clip_id, double duration);
uint64_t track_add_clip(void *engine, int track, double start_time, double duration, const char *name, uint32_t color);
int track_remove_clip(void *engine, int track, uint64_t clip_id);
int track_get_clip_peaks(void *engine, int track, uint64_t clip_id, double start_time, double end_time, int num_peaks, float *peaks_out);

// Clip editing functions
float track_get_clip_fade_in(void *engine, int track, uint64_t clip_id);
float track_get_clip_fade_out(void *engine, int track, uint64_t clip_id);
int track_set_clip_fade_in(void *engine, int track, uint64_t clip_id, float fade_in);
int track_set_clip_fade_out(void *engine, int track, uint64_t clip_id, float fade_out);
double track_get_clip_source_offset(void *engine, int track, uint64_t clip_id);
int track_trim_clip_start(void *engine, int track, uint64_t clip_id, double new_start);
int track_trim_clip_end(void *engine, int track, uint64_t clip_id, double new_end);
uint64_t track_split_clip(void *engine, int track, uint64_t clip_id, double split_time);
float track_get_clip_gain(void *engine, int track, uint64_t clip_id);
int track_set_clip_gain(void *engine, int track, uint64_t clip_id, float gain);

// Effects chain functions (track: 0-3 for tracks, -1 for master)
int get_effect_type_count(void);
const char* get_effect_type_name(int index);
int track_get_effect_count(void *engine, int track);
int track_get_effect_type(void *engine, int track, int slot);
const char* track_get_effect_name(void *engine, int track, int slot);
int track_get_effect_bypassed(void *engine, int track, int slot);
int track_add_effect(void *engine, int track, int effect_type);
int track_remove_effect(void *engine, int track, int slot);
int track_swap_effects(void *engine, int track, int slot_a, int slot_b);
void track_set_effect_bypass(void *engine, int track, int slot, int bypassed);
int track_get_effects_bypassed(void *engine, int track);
void track_set_effects_bypassed(void *engine, int track, int bypassed);
void track_clear_effects(void *engine, int track);

// Effect parameter functions
int effect_get_param_count(void *engine, int track, int slot);
const char* effect_get_param_name(void *engine, int track, int slot, int param);
float effect_get_param_value(void *engine, int track, int slot, int param);
float effect_get_param_min(void *engine, int track, int slot, int param);
float effect_get_param_max(void *engine, int track, int slot, int param);
const char* effect_get_param_unit(void *engine, int track, int slot, int param);
void effect_set_param_value(void *engine, int track, int slot, int param, float value);

// Project/Session management functions
int project_new(void);
int project_save(const char *folder_path);
int project_save_as(const char *folder_path);
int project_load(const char *folder_path);
const char* project_get_name(void);
void project_set_name(const char *name);
float project_get_bpm(void);
void project_set_bpm(float bpm);
int project_get_time_sig_num(void);
int project_get_time_sig_den(void);
void project_set_time_sig(int num, int den);
float project_get_master_volume(void);
void project_set_master_volume(float volume);
int project_is_dirty(void);
int project_has_save_location(void);
const char* project_get_folder_path(void);

// Project track state functions
const char* project_get_track_name(int track);
void project_set_track_name(int track, const char *name);
float project_get_track_volume(int track);
void project_set_track_volume(int track, float volume);
float project_get_track_pan(int track);
void project_set_track_pan(int track, float pan);
int project_get_track_muted(int track);
void project_set_track_muted(int track, int muted);
int project_get_track_solo(int track);
void project_set_track_solo(int track, int solo);

// Audio export functions
int audio_export_wav(void *engine, const char *path, double duration_seconds, int bit_depth);
float audio_export_get_progress(void);
int audio_export_is_done(void);

// Audio recording functions
int recording_init(unsigned int sample_rate);
int recording_start(int track, double start_time);
void recording_stop(void);
int recording_is_active(void);
double recording_get_duration(void);
int recording_save(const char *path);
const float* recording_get_data_ptr(void);
uint64_t recording_get_sample_count(void);
uint32_t recording_get_sample_rate(void);
uint32_t recording_get_peaks(float *out_peaks, uint32_t max_peaks);
double recording_get_start_time(void);
int recording_get_target_track(void);

// Track audio loading
int audio_engine_load_track_audio(void *engine, int track, const float *samples,
                                   uint64_t sample_count, uint8_t num_channels, uint32_t sample_rate);
void audio_engine_clear_track_audio(void *engine, int track);

// MIDI recording functions
int midi_recording_init(void);
int midi_recording_start(uint64_t timestamp);
int midi_recording_stop(void);
int midi_recording_is_active(void);
int midi_recording_get_event_count(void);
double midi_recording_get_duration(void);
void midi_recording_note_on(uint64_t timestamp, uint8_t channel, uint8_t note, uint8_t velocity);
void midi_recording_note_off(uint64_t timestamp, uint8_t channel, uint8_t note, uint8_t velocity);

// MIDI clip functions (for piano roll playback)
void midi_clip_add_demo_notes(int track);
int midi_clip_has_notes(int track);
double midi_clip_get_start_beat(int track);
void midi_clip_set_start_beat(int track, double start_beat);
double midi_clip_get_clip_duration(int track);

// Undo/Redo functions
int undo_init(void);
int undo_undo(void);
int undo_redo(void);
int undo_can_undo(void);
int undo_can_redo(void);
int undo_record_float(int action_type, int track, float old_value, float new_value, const char *desc);
int undo_record_int(int action_type, int track, int old_value, int new_value, const char *desc);
void undo_clear(void);
const char* undo_get_undo_desc(void);
const char* undo_get_redo_desc(void);

// Undo apply callback type: (action_type, track, is_undo, old_int, new_int, old_float, new_float, clip_id)
typedef void (*undo_apply_callback_fn)(int, int, int, int, int, float, float, uint64_t);
void undo_set_apply_callback(undo_apply_callback_fn callback);

// Action types for undo
#define UNDO_SET_TRACK_VOLUME 0
#define UNDO_SET_TRACK_PAN 1
#define UNDO_SET_TRACK_MUTE 2
#define UNDO_SET_TRACK_SOLO 3
#define UNDO_SET_MASTER_VOLUME 4
#define UNDO_ADD_CLIP 5
#define UNDO_REMOVE_CLIP 6
#define UNDO_MOVE_CLIP 7
#define UNDO_SET_BPM 13
#define UNDO_SET_TIME_SIG 14

// Record clip action for undo
int undo_record_clip(int action_type, int track, uint64_t clip_id, const char *desc);

#endif // MAIN_WINDOW_GTK_H
