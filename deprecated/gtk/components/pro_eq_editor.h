/**
 * Pro EQ Editor - FabFilter Pro-Q Style Visual Parametric EQ
 *
 * Features:
 * - 8 fully configurable bands with multiple filter types
 * - Beautiful frequency response curve with gradient fill
 * - Draggable band nodes (drag = freq/gain, scroll = Q)
 * - Click on curve to add bands, right-click to remove
 * - Per-band type selector, solo, and enable controls
 * - Log frequency scale (20Hz - 20kHz)
 */

#ifndef PRO_EQ_EDITOR_H
#define PRO_EQ_EDITOR_H

#include <gtk/gtk.h>

// Create the Pro EQ editor widget
GtkWidget* pro_eq_editor_new(void *audio_engine, int track, int effect_slot);

// Refresh the editor display
void pro_eq_editor_refresh(GtkWidget *editor);

// Get preferred size
void pro_eq_editor_get_preferred_size(int *width, int *height);

#endif // PRO_EQ_EDITOR_H
