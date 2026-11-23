#ifndef LIBRARY_PANEL_GTK_H
#define LIBRARY_PANEL_GTK_H

#include <gtk/gtk.h>
#include <stdbool.h>
#include <stdint.h>

typedef struct LibraryPanel LibraryPanel;

// Library item types
typedef enum {
    LIBRARY_ITEM_INSTRUMENT = 0,
    LIBRARY_ITEM_EFFECT,
    LIBRARY_ITEM_SAMPLE,
    LIBRARY_ITEM_PRESET,
    LIBRARY_ITEM_COUNT
} LibraryItemType;

// Callback when an item is selected/clicked in the library
// track = -1 means "use armed track or track 0"
typedef void (*LibraryDropCallback)(int track, LibraryItemType type, int item_index, void *user_data);

// Instrument functions (from audio engine C API)
extern int audio_engine_get_instrument_type_count(void);
extern const char* audio_engine_get_instrument_type_name(int index);
extern int audio_engine_set_track_instrument(void *engine, int track, int instrument_type);

// Panel lifecycle
LibraryPanel* library_panel_new(void *audio_engine);
GtkWidget* library_panel_get_widget(LibraryPanel *panel);
void library_panel_destroy(LibraryPanel *panel);

// Set drop callback
void library_panel_set_drop_callback(LibraryPanel *panel, LibraryDropCallback callback, void *user_data);

// Get drag data for current drag operation
LibraryItemType library_panel_get_drag_item_type(LibraryPanel *panel);
int library_panel_get_drag_item_index(LibraryPanel *panel);

// Check if panel is currently in a drag operation
bool library_panel_is_dragging(LibraryPanel *panel);

// Get the currently active drag panel (if any)
LibraryPanel* library_panel_get_active_drag(void);

#endif // LIBRARY_PANEL_GTK_H
