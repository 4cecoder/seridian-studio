#include "library_panel_gtk.h"
#include "daw_widgets.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <ctype.h>

// Use shared color scheme from daw_widgets.h
#define TOKYONIGHT_BG         DAW_COLOR_BG
#define TOKYONIGHT_BG_DARK    DAW_COLOR_BG_DARK
#define TOKYONIGHT_CYAN       DAW_COLOR_CYAN
#define TOKYONIGHT_COMMENT    DAW_COLOR_COMMENT
#define TOKYONIGHT_PURPLE     DAW_COLOR_PURPLE
#define TOKYONIGHT_BLUE       DAW_COLOR_BLUE

// Panel constants
#define PANEL_WIDTH 150
#define ITEM_HEIGHT 28

// Category names
static const char* CATEGORY_NAMES[LIBRARY_ITEM_COUNT] = {
    "Instruments",
    "Effects",
    "Samples",
    "Presets"
};

// Category icons (using text for now)
static const char* CATEGORY_ICONS[LIBRARY_ITEM_COUNT] = {
    "🎹",  // Instruments
    "🎛",  // Effects
    "🔊",  // Samples
    "📁"   // Presets
};

// Placeholder effects list
static const char* EFFECT_NAMES[] = {
    "Delay",
    "Reverb",
    "Chorus",
    "Compressor",
    "EQ",
    "Limiter",
    NULL
};

// Placeholder samples list
static const char* SAMPLE_NAMES[] = {
    "Kick 808",
    "Snare Acoustic",
    "Hi-Hat Closed",
    "Hi-Hat Open",
    "Clap",
    "Percussion",
    NULL
};

struct LibraryPanel {
    GtkWidget *main_box;
    GtkWidget *search_entry;
    GtkWidget *category_box;
    GtkWidget *items_scroll;
    GtkWidget *items_box;

    void *audio_engine;

    // Current filter
    char search_filter[256];
    LibraryItemType current_category;

    // Drag state
    bool is_dragging;
    LibraryItemType drag_item_type;
    int drag_item_index;

    // Drop callback
    LibraryDropCallback drop_callback;
    void *drop_user_data;

    // Category buttons for highlighting
    GtkWidget *category_buttons[LIBRARY_ITEM_COUNT];
};

// Forward declarations
static void on_search_changed(GtkSearchEntry *entry, gpointer user_data);
static void on_category_clicked(GtkButton *button, gpointer user_data);
static void refresh_items_list(LibraryPanel *panel);
static GtkWidget* create_library_item(LibraryPanel *panel, const char *name, const char *icon,
                                       LibraryItemType type, int index);

// Case-insensitive substring search
static bool str_contains_ci(const char *haystack, const char *needle) {
    if (!needle || needle[0] == '\0') return true;
    if (!haystack) return false;

    size_t needle_len = strlen(needle);
    size_t haystack_len = strlen(haystack);

    if (needle_len > haystack_len) return false;

    for (size_t i = 0; i <= haystack_len - needle_len; i++) {
        bool match = true;
        for (size_t j = 0; j < needle_len; j++) {
            if (tolower((unsigned char)haystack[i + j]) != tolower((unsigned char)needle[j])) {
                match = false;
                break;
            }
        }
        if (match) return true;
    }
    return false;
}

// Search changed handler
static void on_search_changed(GtkSearchEntry *entry, gpointer user_data) {
    LibraryPanel *panel = (LibraryPanel *)user_data;
    if (!panel) return;

    const char *text = gtk_editable_get_text(GTK_EDITABLE(entry));
    strncpy(panel->search_filter, text ? text : "", sizeof(panel->search_filter) - 1);
    panel->search_filter[sizeof(panel->search_filter) - 1] = '\0';

    refresh_items_list(panel);
}

// Category button clicked
static void on_category_clicked(GtkButton *button, gpointer user_data) {
    LibraryPanel *panel = (LibraryPanel *)user_data;
    if (!panel) return;

    // Find which category was clicked
    for (int i = 0; i < LIBRARY_ITEM_COUNT; i++) {
        if ((void *)button == (void *)panel->category_buttons[i]) {
            panel->current_category = (LibraryItemType)i;

            // Update button styling
            for (int j = 0; j < LIBRARY_ITEM_COUNT; j++) {
                if (j == i) {
                    gtk_widget_add_css_class(panel->category_buttons[j], "suggested-action");
                } else {
                    gtk_widget_remove_css_class(panel->category_buttons[j], "suggested-action");
                }
            }

            refresh_items_list(panel);
            break;
        }
    }
}

// Item clicked - select it for loading
static void on_item_clicked(GtkButton *button, gpointer user_data) {
    LibraryPanel *panel = (LibraryPanel *)user_data;
    if (!panel) return;

    int type = GPOINTER_TO_INT(g_object_get_data(G_OBJECT(button), "item-type"));
    int index = GPOINTER_TO_INT(g_object_get_data(G_OBJECT(button), "item-index"));

    // Store selected item
    panel->drag_item_type = type;
    panel->drag_item_index = index;
    panel->is_dragging = true;  // Use as "item selected" flag

    // Call drop callback if set (for immediate loading to armed track)
    if (panel->drop_callback) {
        panel->drop_callback(-1, type, index, panel->drop_user_data);  // -1 = use armed track
    }

    printf("📚 Selected: type=%d index=%d\n", type, index);
}

// Global pointer to active drag panel (for cross-widget drag tracking)
static LibraryPanel *g_active_drag_panel = NULL;

// Get the currently dragging panel (if any) - for use by main window
LibraryPanel* library_panel_get_active_drag(void) {
    return g_active_drag_panel;
}

// Custom drag using gesture - button press starts tracking
static void on_item_drag_begin(GtkGestureDrag *gesture, double start_x, double start_y, gpointer user_data) {
    (void)gesture;
    (void)start_x;
    (void)start_y;

    GtkWidget *widget = GTK_WIDGET(user_data);
    LibraryPanel *panel = (LibraryPanel *)g_object_get_data(G_OBJECT(widget), "panel");
    if (!panel) return;

    int type = GPOINTER_TO_INT(g_object_get_data(G_OBJECT(widget), "item-type"));
    int index = GPOINTER_TO_INT(g_object_get_data(G_OBJECT(widget), "item-index"));

    panel->is_dragging = true;
    panel->drag_item_type = (LibraryItemType)type;
    panel->drag_item_index = index;
    g_active_drag_panel = panel;

    printf("🎯 Drag begin: type=%d index=%d\n", type, index);
}

// Custom drag update - track mouse movement
static void on_item_drag_update(GtkGestureDrag *gesture, double offset_x, double offset_y, gpointer user_data) {
    (void)gesture;
    (void)offset_x;
    (void)offset_y;
    (void)user_data;
    // Could show visual feedback here
}

// Custom drag end - check if dropped on timeline
static void on_item_drag_end(GtkGestureDrag *gesture, double offset_x, double offset_y, gpointer user_data) {
    GtkWidget *widget = GTK_WIDGET(user_data);
    LibraryPanel *panel = (LibraryPanel *)g_object_get_data(G_OBJECT(widget), "panel");
    if (!panel) return;

    // Get the end coordinates relative to root window
    double start_x, start_y;
    gtk_gesture_drag_get_start_point(gesture, &start_x, &start_y);

    // Unused but might be useful for future visual feedback
    (void)start_x;
    (void)start_y;

    printf("🎯 Drag end: offset=(%.0f, %.0f)\n", offset_x, offset_y);

    // If dragged to the left (negative offset), treat as drop on timeline
    // This is a simple heuristic - drag left means dropping on timeline area
    if (offset_x < -50 && panel->is_dragging) {
        printf("📥 Detected drop to timeline area\n");

        // Notify via callback - pass -2 as track to indicate "calculate from cursor position"
        // The main window will determine the track from the current cursor position
        if (panel->drop_callback) {
            panel->drop_callback(-2, panel->drag_item_type, panel->drag_item_index, panel->drop_user_data);
        }
    }

    panel->is_dragging = false;
    g_active_drag_panel = NULL;
}

// Create a clickable library item widget with drag source
static GtkWidget* create_library_item(LibraryPanel *panel, const char *name, const char *icon,
                                       LibraryItemType type, int index) {
    GtkWidget *item_box = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 6);
    gtk_widget_set_margin_start(item_box, 4);
    gtk_widget_set_margin_end(item_box, 4);
    gtk_widget_set_margin_top(item_box, 2);
    gtk_widget_set_margin_bottom(item_box, 2);
    gtk_widget_set_size_request(item_box, -1, ITEM_HEIGHT);

    // Icon
    GtkWidget *icon_label = gtk_label_new(icon);
    gtk_box_append(GTK_BOX(item_box), icon_label);

    // Name
    GtkWidget *name_label = gtk_label_new(name);
    gtk_widget_set_hexpand(name_label, TRUE);
    gtk_widget_set_halign(name_label, GTK_ALIGN_START);
    gtk_box_append(GTK_BOX(item_box), name_label);

    // Wrap in a button for click interaction
    GtkWidget *item_button = gtk_button_new();
    gtk_button_set_child(GTK_BUTTON(item_button), item_box);
    gtk_widget_add_css_class(item_button, "flat");

    // Store item data and panel reference
    g_object_set_data(G_OBJECT(item_button), "item-type", GINT_TO_POINTER(type));
    g_object_set_data(G_OBJECT(item_button), "item-index", GINT_TO_POINTER(index));
    g_object_set_data(G_OBJECT(item_button), "panel", panel);

    // Connect click handler - clicking loads the item to armed track
    g_signal_connect(item_button, "clicked", G_CALLBACK(on_item_clicked), panel);

    // Add custom drag gesture for drag-and-drop to tracks
    // Using GtkGestureDrag instead of GtkDragSource to bypass macOS pasteboard crash
    GtkGesture *drag_gesture = gtk_gesture_drag_new();
    g_signal_connect(drag_gesture, "drag-begin", G_CALLBACK(on_item_drag_begin), item_button);
    g_signal_connect(drag_gesture, "drag-update", G_CALLBACK(on_item_drag_update), item_button);
    g_signal_connect(drag_gesture, "drag-end", G_CALLBACK(on_item_drag_end), item_button);
    gtk_widget_add_controller(item_button, GTK_EVENT_CONTROLLER(drag_gesture));

    return item_button;
}

// Refresh the items list based on current category and filter
static void refresh_items_list(LibraryPanel *panel) {
    if (!panel || !panel->items_box) return;

    // Clear existing items
    GtkWidget *child = gtk_widget_get_first_child(panel->items_box);
    while (child) {
        GtkWidget *next = gtk_widget_get_next_sibling(child);
        gtk_box_remove(GTK_BOX(panel->items_box), child);
        child = next;
    }

    const char *filter = panel->search_filter;

    switch (panel->current_category) {
        case LIBRARY_ITEM_INSTRUMENT: {
            int count = audio_engine_get_instrument_type_count();
            for (int i = 0; i < count; i++) {
                const char *name = audio_engine_get_instrument_type_name(i);
                if (str_contains_ci(name, filter)) {
                    GtkWidget *item = create_library_item(panel, name, "🎹",
                                                          LIBRARY_ITEM_INSTRUMENT, i);
                    gtk_box_append(GTK_BOX(panel->items_box), item);
                }
            }
            break;
        }

        case LIBRARY_ITEM_EFFECT: {
            for (int i = 0; EFFECT_NAMES[i] != NULL; i++) {
                if (str_contains_ci(EFFECT_NAMES[i], filter)) {
                    GtkWidget *item = create_library_item(panel, EFFECT_NAMES[i], "🎛",
                                                          LIBRARY_ITEM_EFFECT, i);
                    gtk_box_append(GTK_BOX(panel->items_box), item);
                }
            }
            break;
        }

        case LIBRARY_ITEM_SAMPLE: {
            for (int i = 0; SAMPLE_NAMES[i] != NULL; i++) {
                if (str_contains_ci(SAMPLE_NAMES[i], filter)) {
                    GtkWidget *item = create_library_item(panel, SAMPLE_NAMES[i], "🔊",
                                                          LIBRARY_ITEM_SAMPLE, i);
                    gtk_box_append(GTK_BOX(panel->items_box), item);
                }
            }
            break;
        }

        case LIBRARY_ITEM_PRESET: {
            // Placeholder - no presets yet
            GtkWidget *placeholder = gtk_label_new("No presets available");
            gtk_widget_set_margin_top(placeholder, 20);
            gtk_box_append(GTK_BOX(panel->items_box), placeholder);
            break;
        }

        default:
            break;
    }
}

// Create the library panel
LibraryPanel* library_panel_new(void *audio_engine) {
    LibraryPanel *panel = malloc(sizeof(LibraryPanel));
    if (!panel) return NULL;

    memset(panel, 0, sizeof(LibraryPanel));
    panel->audio_engine = audio_engine;
    panel->current_category = LIBRARY_ITEM_INSTRUMENT;

    // Main container
    panel->main_box = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0);
    gtk_widget_set_size_request(panel->main_box, PANEL_WIDTH, -1);
    gtk_widget_set_hexpand(panel->main_box, FALSE);  // Don't expand horizontally

    // Header with title
    GtkWidget *header = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 0);
    gtk_widget_set_margin_start(header, 8);
    gtk_widget_set_margin_end(header, 8);
    gtk_widget_set_margin_top(header, 6);
    gtk_widget_set_margin_bottom(header, 4);

    GtkWidget *title = gtk_label_new(NULL);
    gtk_label_set_markup(GTK_LABEL(title), "<b>Library</b>");
    gtk_widget_set_halign(title, GTK_ALIGN_START);
    gtk_box_append(GTK_BOX(header), title);

    gtk_box_append(GTK_BOX(panel->main_box), header);

    // Search entry
    panel->search_entry = gtk_search_entry_new();
    gtk_widget_set_margin_start(panel->search_entry, 6);
    gtk_widget_set_margin_end(panel->search_entry, 6);
    gtk_widget_set_margin_bottom(panel->search_entry, 4);
    g_signal_connect(panel->search_entry, "search-changed", G_CALLBACK(on_search_changed), panel);
    gtk_box_append(GTK_BOX(panel->main_box), panel->search_entry);

    // Category buttons
    panel->category_box = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 2);
    gtk_widget_set_margin_start(panel->category_box, 6);
    gtk_widget_set_margin_end(panel->category_box, 6);
    gtk_widget_set_margin_bottom(panel->category_box, 4);

    for (int i = 0; i < LIBRARY_ITEM_COUNT; i++) {
        GtkWidget *btn = gtk_button_new_with_label(CATEGORY_ICONS[i]);
        gtk_widget_set_tooltip_text(btn, CATEGORY_NAMES[i]);
        gtk_widget_set_hexpand(btn, TRUE);
        panel->category_buttons[i] = btn;
        g_signal_connect(btn, "clicked", G_CALLBACK(on_category_clicked), panel);
        gtk_box_append(GTK_BOX(panel->category_box), btn);
    }

    // Highlight first category
    gtk_widget_add_css_class(panel->category_buttons[0], "suggested-action");

    gtk_box_append(GTK_BOX(panel->main_box), panel->category_box);

    // Separator
    GtkWidget *sep = gtk_separator_new(GTK_ORIENTATION_HORIZONTAL);
    gtk_box_append(GTK_BOX(panel->main_box), sep);

    // Scrollable items list
    panel->items_scroll = gtk_scrolled_window_new();
    gtk_scrolled_window_set_policy(GTK_SCROLLED_WINDOW(panel->items_scroll),
                                   GTK_POLICY_NEVER, GTK_POLICY_AUTOMATIC);
    gtk_widget_set_vexpand(panel->items_scroll, TRUE);

    panel->items_box = gtk_box_new(GTK_ORIENTATION_VERTICAL, 2);
    gtk_widget_set_margin_top(panel->items_box, 4);

    gtk_scrolled_window_set_child(GTK_SCROLLED_WINDOW(panel->items_scroll), panel->items_box);
    gtk_box_append(GTK_BOX(panel->main_box), panel->items_scroll);

    // Info footer
    GtkWidget *footer = gtk_label_new(NULL);
    gtk_label_set_markup(GTK_LABEL(footer),
        "<span size='small' foreground='" TOKYONIGHT_COMMENT "'>Drag items to tracks</span>");
    gtk_widget_set_margin_top(footer, 8);
    gtk_widget_set_margin_bottom(footer, 8);
    gtk_box_append(GTK_BOX(panel->main_box), footer);

    // Initial population
    refresh_items_list(panel);

    printf("📚 Library panel created\n");

    return panel;
}

GtkWidget* library_panel_get_widget(LibraryPanel *panel) {
    return panel ? panel->main_box : NULL;
}

void library_panel_destroy(LibraryPanel *panel) {
    if (!panel) return;
    // Widget will be destroyed by parent
    free(panel);
    printf("📚 Library panel destroyed\n");
}

void library_panel_set_drop_callback(LibraryPanel *panel, LibraryDropCallback callback, void *user_data) {
    if (!panel) return;
    panel->drop_callback = callback;
    panel->drop_user_data = user_data;
}

LibraryItemType library_panel_get_drag_item_type(LibraryPanel *panel) {
    return panel ? panel->drag_item_type : LIBRARY_ITEM_INSTRUMENT;
}

int library_panel_get_drag_item_index(LibraryPanel *panel) {
    return panel ? panel->drag_item_index : 0;
}

bool library_panel_is_dragging(LibraryPanel *panel) {
    return panel ? panel->is_dragging : false;
}
