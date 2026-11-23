/**
 * Parametric EQ Editor - FabFilter Pro-Q Style Visual EQ
 *
 * Features:
 * - Frequency response curve display
 * - Draggable band nodes
 * - Visual representation of each band
 * - Log frequency scale (20Hz - 20kHz)
 * - dB scale for gain (-18 to +18 dB)
 */

#ifndef PARAMETRIC_EQ_EDITOR_H
#define PARAMETRIC_EQ_EDITOR_H

#include <gtk/gtk.h>

// Forward declaration
typedef struct ParametricEQEditor ParametricEQEditor;

/**
 * Create a new Parametric EQ editor
 *
 * @param audio_engine  Pointer to audio engine
 * @param track         Track index (0-3) or -1 for master
 * @param effect_slot   Effect slot index in the chain
 * @return Container widget for the EQ editor
 */
GtkWidget* parametric_eq_editor_new(void *audio_engine, int track, int effect_slot);

/**
 * Update the EQ display (call when parameters change externally)
 */
void parametric_eq_editor_refresh(GtkWidget *editor);

/**
 * Set the effect slot (when effect moves in chain)
 */
void parametric_eq_editor_set_slot(GtkWidget *editor, int slot);

#endif // PARAMETRIC_EQ_EDITOR_H
