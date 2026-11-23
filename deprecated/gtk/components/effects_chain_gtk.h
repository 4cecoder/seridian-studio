#ifndef EFFECTS_CHAIN_GTK_H
#define EFFECTS_CHAIN_GTK_H

#include <gtk/gtk.h>
#include <stdbool.h>
#include <stdint.h>

typedef struct EffectsChainEditor EffectsChainEditor;

// Effects chain control functions (from Zig audio engine C API)
extern int get_effect_type_count(void);
extern const char* get_effect_type_name(int index);
extern int track_get_effect_count(void *engine, int track);
extern int track_get_effect_type(void *engine, int track, int slot);
extern const char* track_get_effect_name(void *engine, int track, int slot);
extern int track_get_effect_bypassed(void *engine, int track, int slot);
extern int track_add_effect(void *engine, int track, int effect_type);
extern int track_remove_effect(void *engine, int track, int slot);
extern int track_swap_effects(void *engine, int track, int slot_a, int slot_b);
extern void track_set_effect_bypass(void *engine, int track, int slot, int bypassed);
extern int track_get_effects_bypassed(void *engine, int track);
extern void track_set_effects_bypassed(void *engine, int track, int bypassed);
extern void track_clear_effects(void *engine, int track);

// Effect parameter functions
extern int effect_get_param_count(void *engine, int track, int slot);
extern const char* effect_get_param_name(void *engine, int track, int slot, int param);
extern float effect_get_param_value(void *engine, int track, int slot, int param);
extern float effect_get_param_min(void *engine, int track, int slot, int param);
extern float effect_get_param_max(void *engine, int track, int slot, int param);
extern const char* effect_get_param_unit(void *engine, int track, int slot, int param);
extern void effect_set_param_value(void *engine, int track, int slot, int param, float value);

// Editor lifecycle
// track: 0-3 for tracks, -1 for master
EffectsChainEditor* effects_chain_editor_new(GtkWindow *parent, void *audio_engine, int track);
void effects_chain_editor_show(EffectsChainEditor *editor);
void effects_chain_editor_hide(EffectsChainEditor *editor);
void effects_chain_editor_destroy(EffectsChainEditor *editor);

// Update display
void effects_chain_editor_refresh(EffectsChainEditor *editor);

#endif // EFFECTS_CHAIN_GTK_H
