/**
 * Effect Modal - Standalone floating window for individual effects
 *
 * Opens a dedicated window for any effect, allowing multiple effects
 * to be edited simultaneously. Windows can be positioned anywhere
 * on screen for a flexible mixing workflow.
 */

#ifndef EFFECT_MODAL_GTK_H
#define EFFECT_MODAL_GTK_H

#include <gtk/gtk.h>

// Forward declaration
typedef struct EffectModal EffectModal;

/**
 * Create and show a new effect modal window
 *
 * @param parent       Parent window (for positioning, can be NULL)
 * @param audio_engine Pointer to audio engine
 * @param track        Track index (0-3) or -1 for master
 * @param effect_slot  Effect slot index in the chain
 * @return The EffectModal instance (caller should track for cleanup)
 */
EffectModal* effect_modal_new(GtkWindow *parent, void *audio_engine, int track, int effect_slot);

/**
 * Show an existing effect modal
 */
void effect_modal_show(EffectModal *modal);

/**
 * Hide an effect modal
 */
void effect_modal_hide(EffectModal *modal);

/**
 * Destroy an effect modal and free resources
 */
void effect_modal_destroy(EffectModal *modal);

/**
 * Check if modal is for a specific effect
 */
int effect_modal_matches(EffectModal *modal, int track, int effect_slot);

/**
 * Update modal if effect slot changed (e.g., reordering)
 */
void effect_modal_update_slot(EffectModal *modal, int new_slot);

/**
 * Refresh the modal's parameter display
 */
void effect_modal_refresh(EffectModal *modal);

/**
 * Get the modal's window widget
 */
GtkWidget* effect_modal_get_window(EffectModal *modal);

#endif // EFFECT_MODAL_GTK_H
