#include "effects_chain_gtk.h"
#include "effect_modal_gtk.h"
#include "daw_widgets.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

// Use shared color scheme from daw_widgets.h
#define TOKYONIGHT_CYAN DAW_COLOR_CYAN

// Modal size constants
#define MODAL_WIDTH 400
#define MODAL_HEIGHT 500

// Maximum effects in chain
#define MAX_EFFECTS 8
#define MAX_OPEN_MODALS 16

struct EffectsChainEditor {
    GtkWidget *window;
    GtkWidget *effects_list_box;     // ListBox for effect slots
    GtkWidget *add_dropdown;         // Dropdown to add new effect
    GtkWidget *chain_bypass_check;   // Bypass entire chain
    GtkWidget *no_effects_label;     // "No effects" placeholder

    void *audio_engine;
    int track;                       // 0-3 for tracks, -1 for master
    int selected_slot;               // Currently selected effect slot (-1 = none)

    // Context menu
    GtkWidget *context_menu;
    int context_slot;                // Slot for context menu action

    // Open effect modals (floating windows)
    EffectModal *open_modals[MAX_OPEN_MODALS];
    int modal_count;
};

// Forward declarations
static void update_effects_list(EffectsChainEditor *editor);
static void on_add_effect(GtkDropDown *dropdown, GParamSpec *pspec, gpointer user_data);
static void on_bypass_toggled(GtkCheckButton *check, gpointer user_data);
static void on_effect_bypass_toggled(GtkCheckButton *check, gpointer user_data);
static void on_effect_delete_clicked(GtkButton *button, gpointer user_data);
static void on_effect_edit_clicked(GtkButton *button, gpointer user_data);
static void on_move_up_clicked(GtkButton *button, gpointer user_data);
static void on_move_down_clicked(GtkButton *button, gpointer user_data);
static void on_row_activated(GtkListBox *box, GtkListBoxRow *row, gpointer user_data);

// Modal management
static EffectModal* find_or_create_modal(EffectsChainEditor *editor, int slot);
static void close_modal_for_slot(EffectsChainEditor *editor, int slot);
static void update_modal_slots_after_remove(EffectsChainEditor *editor, int removed_slot);
static void update_modal_slots_after_swap(EffectsChainEditor *editor, int slot_a, int slot_b);

// Get title for window
static const char* get_editor_title(int track) {
    static char title[64];
    if (track < 0) {
        snprintf(title, sizeof(title), "Master Effects");
    } else {
        snprintf(title, sizeof(title), "Track %d Effects", track + 1);
    }
    return title;
}

// Modal management functions
static EffectModal* find_or_create_modal(EffectsChainEditor *editor, int slot) {
    // Check if modal already exists for this slot
    for (int i = 0; i < editor->modal_count; i++) {
        if (effect_modal_matches(editor->open_modals[i], editor->track, slot)) {
            effect_modal_show(editor->open_modals[i]);
            return editor->open_modals[i];
        }
    }

    // Create new modal if we have room
    if (editor->modal_count >= MAX_OPEN_MODALS) {
        printf("Maximum number of effect windows open\n");
        return NULL;
    }

    EffectModal *modal = effect_modal_new(GTK_WINDOW(editor->window),
                                          editor->audio_engine, editor->track, slot);
    if (modal) {
        editor->open_modals[editor->modal_count++] = modal;
        effect_modal_show(modal);
    }

    return modal;
}

static void close_modal_for_slot(EffectsChainEditor *editor, int slot) {
    for (int i = 0; i < editor->modal_count; i++) {
        if (effect_modal_matches(editor->open_modals[i], editor->track, slot)) {
            effect_modal_destroy(editor->open_modals[i]);
            // Shift remaining modals down
            for (int j = i; j < editor->modal_count - 1; j++) {
                editor->open_modals[j] = editor->open_modals[j + 1];
            }
            editor->modal_count--;
            return;
        }
    }
}

static void update_modal_slots_after_remove(EffectsChainEditor *editor, int removed_slot) {
    // Close modal for removed slot
    close_modal_for_slot(editor, removed_slot);

    // Update slots for modals that were after the removed one
    for (int i = 0; i < editor->modal_count; i++) {
        // Check if this modal's slot needs to be decremented
        // (modals for slots > removed_slot need their slot index reduced by 1)
        for (int s = removed_slot + 1; s < MAX_EFFECTS; s++) {
            if (effect_modal_matches(editor->open_modals[i], editor->track, s)) {
                effect_modal_update_slot(editor->open_modals[i], s - 1);
                break;
            }
        }
    }
}

static void update_modal_slots_after_swap(EffectsChainEditor *editor, int slot_a, int slot_b) {
    EffectModal *modal_a = NULL;
    EffectModal *modal_b = NULL;
    int idx_a = -1, idx_b = -1;

    // Find modals for both slots
    for (int i = 0; i < editor->modal_count; i++) {
        if (effect_modal_matches(editor->open_modals[i], editor->track, slot_a)) {
            modal_a = editor->open_modals[i];
            idx_a = i;
        }
        if (effect_modal_matches(editor->open_modals[i], editor->track, slot_b)) {
            modal_b = editor->open_modals[i];
            idx_b = i;
        }
    }

    // Update slot indices
    if (modal_a) effect_modal_update_slot(modal_a, slot_b);
    if (modal_b) effect_modal_update_slot(modal_b, slot_a);
}

// Create a single effect slot widget
static GtkWidget* create_effect_slot(EffectsChainEditor *editor, int slot) {
    const char *name = track_get_effect_name(editor->audio_engine, editor->track, slot);
    int bypassed = track_get_effect_bypassed(editor->audio_engine, editor->track, slot);

    // Main container for the slot
    GtkWidget *box = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8);
    gtk_widget_set_margin_start(box, 8);
    gtk_widget_set_margin_end(box, 8);
    gtk_widget_set_margin_top(box, 6);
    gtk_widget_set_margin_bottom(box, 6);

    // Slot number label
    char slot_label[8];
    snprintf(slot_label, sizeof(slot_label), "%d.", slot + 1);
    GtkWidget *num_label = gtk_label_new(slot_label);
    gtk_widget_set_size_request(num_label, 20, -1);
    gtk_box_append(GTK_BOX(box), num_label);

    // Effect name (clickable area)
    GtkWidget *name_label = gtk_label_new(name);
    gtk_widget_set_hexpand(name_label, TRUE);
    gtk_widget_set_halign(name_label, GTK_ALIGN_START);
    if (bypassed) {
        gtk_widget_set_opacity(name_label, 0.5);
    }
    gtk_box_append(GTK_BOX(box), name_label);

    // Edit button (opens modal)
    GtkWidget *edit_btn = gtk_button_new_with_label("Edit");
    gtk_widget_set_tooltip_text(edit_btn, "Open effect controls (double-click row)");
    g_object_set_data(G_OBJECT(edit_btn), "slot", GINT_TO_POINTER(slot));
    g_signal_connect(edit_btn, "clicked", G_CALLBACK(on_effect_edit_clicked), editor);
    gtk_box_append(GTK_BOX(box), edit_btn);

    // Move up button
    GtkWidget *up_btn = gtk_button_new_with_label("\u25B2");  // Up arrow
    gtk_widget_set_size_request(up_btn, 28, -1);
    gtk_widget_set_tooltip_text(up_btn, "Move Up");
    g_object_set_data(G_OBJECT(up_btn), "slot", GINT_TO_POINTER(slot));
    g_signal_connect(up_btn, "clicked", G_CALLBACK(on_move_up_clicked), editor);
    gtk_box_append(GTK_BOX(box), up_btn);

    // Move down button
    GtkWidget *down_btn = gtk_button_new_with_label("\u25BC");  // Down arrow
    gtk_widget_set_size_request(down_btn, 28, -1);
    gtk_widget_set_tooltip_text(down_btn, "Move Down");
    g_object_set_data(G_OBJECT(down_btn), "slot", GINT_TO_POINTER(slot));
    g_signal_connect(down_btn, "clicked", G_CALLBACK(on_move_down_clicked), editor);
    gtk_box_append(GTK_BOX(box), down_btn);

    // Bypass checkbox
    GtkWidget *bypass_check = gtk_check_button_new_with_label("Bypass");
    gtk_check_button_set_active(GTK_CHECK_BUTTON(bypass_check), bypassed);
    g_object_set_data(G_OBJECT(bypass_check), "slot", GINT_TO_POINTER(slot));
    g_signal_connect(bypass_check, "toggled", G_CALLBACK(on_effect_bypass_toggled), editor);
    gtk_box_append(GTK_BOX(box), bypass_check);

    // Delete button
    GtkWidget *delete_btn = gtk_button_new_with_label("\u2715");  // X mark
    gtk_widget_add_css_class(delete_btn, "destructive-action");
    gtk_widget_set_size_request(delete_btn, 28, -1);
    gtk_widget_set_tooltip_text(delete_btn, "Remove Effect");
    g_object_set_data(G_OBJECT(delete_btn), "slot", GINT_TO_POINTER(slot));
    g_signal_connect(delete_btn, "clicked", G_CALLBACK(on_effect_delete_clicked), editor);
    gtk_box_append(GTK_BOX(box), delete_btn);

    return box;
}

// Update the effects list
static void update_effects_list(EffectsChainEditor *editor) {
    // Remove all children from list box
    GtkWidget *child = gtk_widget_get_first_child(GTK_WIDGET(editor->effects_list_box));
    while (child) {
        GtkWidget *next = gtk_widget_get_next_sibling(child);
        gtk_list_box_remove(GTK_LIST_BOX(editor->effects_list_box), child);
        child = next;
    }

    int count = track_get_effect_count(editor->audio_engine, editor->track);

    if (count == 0) {
        // Show "No effects" label
        gtk_widget_set_visible(editor->no_effects_label, TRUE);
        editor->selected_slot = -1;
    } else {
        gtk_widget_set_visible(editor->no_effects_label, FALSE);

        // Add effect slots
        for (int i = 0; i < count; i++) {
            GtkWidget *slot_widget = create_effect_slot(editor, i);
            GtkWidget *row = gtk_list_box_row_new();
            gtk_list_box_row_set_child(GTK_LIST_BOX_ROW(row), slot_widget);
            g_object_set_data(G_OBJECT(row), "slot", GINT_TO_POINTER(i));
            gtk_list_box_row_set_activatable(GTK_LIST_BOX_ROW(row), TRUE);
            gtk_list_box_append(GTK_LIST_BOX(editor->effects_list_box), row);
        }

        // Select first effect if none selected
        if (editor->selected_slot < 0 || editor->selected_slot >= count) {
            editor->selected_slot = 0;
        }
    }

    // Update chain bypass checkbox
    int chain_bypassed = track_get_effects_bypassed(editor->audio_engine, editor->track);
    gtk_check_button_set_active(GTK_CHECK_BUTTON(editor->chain_bypass_check), chain_bypassed);
}

// Callbacks

// Edit button clicked - open effect modal
static void on_effect_edit_clicked(GtkButton *button, gpointer user_data) {
    EffectsChainEditor *editor = (EffectsChainEditor *)user_data;
    if (!editor) return;

    int slot = GPOINTER_TO_INT(g_object_get_data(G_OBJECT(button), "slot"));
    find_or_create_modal(editor, slot);
}

// Row double-clicked - open effect modal
static void on_row_activated(GtkListBox *box, GtkListBoxRow *row, gpointer user_data) {
    (void)box;
    EffectsChainEditor *editor = (EffectsChainEditor *)user_data;
    if (!editor || !row) return;

    int slot = GPOINTER_TO_INT(g_object_get_data(G_OBJECT(row), "slot"));
    find_or_create_modal(editor, slot);
}

static void on_add_effect(GtkDropDown *dropdown, GParamSpec *pspec, gpointer user_data) {
    (void)pspec;
    EffectsChainEditor *editor = (EffectsChainEditor *)user_data;
    if (!editor) return;

    guint selected = gtk_drop_down_get_selected(dropdown);

    // Index 0 is "Add Effect..." placeholder
    if (selected == 0) return;

    // Add effect (index - 1 to skip placeholder)
    int effect_type = (int)(selected - 1);
    int result = track_add_effect(editor->audio_engine, editor->track, effect_type);

    if (result >= 0) {
        printf("Added effect '%s' at slot %d\n", get_effect_type_name(effect_type), result);
        editor->selected_slot = result;
        update_effects_list(editor);
    } else {
        printf("Failed to add effect\n");
    }

    // Reset dropdown to placeholder
    gtk_drop_down_set_selected(dropdown, 0);
}

static void on_bypass_toggled(GtkCheckButton *check, gpointer user_data) {
    EffectsChainEditor *editor = (EffectsChainEditor *)user_data;
    if (!editor) return;

    gboolean active = gtk_check_button_get_active(check);
    track_set_effects_bypassed(editor->audio_engine, editor->track, active ? 1 : 0);
}

static void on_effect_bypass_toggled(GtkCheckButton *check, gpointer user_data) {
    EffectsChainEditor *editor = (EffectsChainEditor *)user_data;
    if (!editor) return;

    int slot = GPOINTER_TO_INT(g_object_get_data(G_OBJECT(check), "slot"));
    gboolean active = gtk_check_button_get_active(check);
    track_set_effect_bypass(editor->audio_engine, editor->track, slot, active ? 1 : 0);
}

static void on_effect_delete_clicked(GtkButton *button, gpointer user_data) {
    EffectsChainEditor *editor = (EffectsChainEditor *)user_data;
    if (!editor) return;

    int slot = GPOINTER_TO_INT(g_object_get_data(G_OBJECT(button), "slot"));

    // Update modals before removing
    update_modal_slots_after_remove(editor, slot);

    int result = track_remove_effect(editor->audio_engine, editor->track, slot);
    if (result == 0) {
        printf("Removed effect at slot %d\n", slot);

        // Adjust selection
        int count = track_get_effect_count(editor->audio_engine, editor->track);
        if (editor->selected_slot >= count) {
            editor->selected_slot = count - 1;
        }

        update_effects_list(editor);
    }
}

static void on_move_up_clicked(GtkButton *button, gpointer user_data) {
    EffectsChainEditor *editor = (EffectsChainEditor *)user_data;
    if (!editor) return;

    int slot = GPOINTER_TO_INT(g_object_get_data(G_OBJECT(button), "slot"));

    if (slot > 0) {
        track_swap_effects(editor->audio_engine, editor->track, slot, slot - 1);
        update_modal_slots_after_swap(editor, slot, slot - 1);
        editor->selected_slot = slot - 1;
        update_effects_list(editor);
    }
}

static void on_move_down_clicked(GtkButton *button, gpointer user_data) {
    EffectsChainEditor *editor = (EffectsChainEditor *)user_data;
    if (!editor) return;

    int slot = GPOINTER_TO_INT(g_object_get_data(G_OBJECT(button), "slot"));
    int count = track_get_effect_count(editor->audio_engine, editor->track);

    if (slot < count - 1) {
        track_swap_effects(editor->audio_engine, editor->track, slot, slot + 1);
        update_modal_slots_after_swap(editor, slot, slot + 1);
        editor->selected_slot = slot + 1;
        update_effects_list(editor);
    }
}

// Handle window close - hide instead of destroy
static gboolean on_window_close_request(GtkWindow *window, gpointer user_data) {
    (void)user_data;
    // Hide window instead of destroying
    gtk_widget_set_visible(GTK_WIDGET(window), FALSE);
    return TRUE;  // Prevent default destroy behavior
}

// Keyboard handler
static gboolean on_key_pressed(GtkEventControllerKey *controller, guint keyval, guint keycode, GdkModifierType state, gpointer user_data) {
    (void)controller;
    (void)keycode;
    (void)state;

    EffectsChainEditor *editor = (EffectsChainEditor *)user_data;
    if (!editor) return FALSE;

    int count = track_get_effect_count(editor->audio_engine, editor->track);

    switch (keyval) {
        case GDK_KEY_Up:
            // Move selection up
            if (editor->selected_slot > 0) {
                editor->selected_slot--;
                GtkListBoxRow *row = gtk_list_box_get_row_at_index(
                    GTK_LIST_BOX(editor->effects_list_box), editor->selected_slot);
                if (row) {
                    gtk_list_box_select_row(GTK_LIST_BOX(editor->effects_list_box), row);
                }
            }
            return TRUE;

        case GDK_KEY_Down:
            // Move selection down
            if (editor->selected_slot < count - 1) {
                editor->selected_slot++;
                GtkListBoxRow *row = gtk_list_box_get_row_at_index(
                    GTK_LIST_BOX(editor->effects_list_box), editor->selected_slot);
                if (row) {
                    gtk_list_box_select_row(GTK_LIST_BOX(editor->effects_list_box), row);
                }
            }
            return TRUE;

        case GDK_KEY_Return:
        case GDK_KEY_KP_Enter:
            // Open modal for selected effect
            if (editor->selected_slot >= 0 && editor->selected_slot < count) {
                find_or_create_modal(editor, editor->selected_slot);
            }
            return TRUE;

        case GDK_KEY_Delete:
        case GDK_KEY_BackSpace:
            // Delete selected effect
            if (editor->selected_slot >= 0 && editor->selected_slot < count) {
                update_modal_slots_after_remove(editor, editor->selected_slot);
                track_remove_effect(editor->audio_engine, editor->track, editor->selected_slot);
                count = track_get_effect_count(editor->audio_engine, editor->track);
                if (editor->selected_slot >= count) {
                    editor->selected_slot = count - 1;
                }
                update_effects_list(editor);
            }
            return TRUE;

        case GDK_KEY_b:
        case GDK_KEY_B:
            // Toggle bypass on selected
            if (editor->selected_slot >= 0 && editor->selected_slot < count) {
                int bypassed = track_get_effect_bypassed(editor->audio_engine, editor->track, editor->selected_slot);
                track_set_effect_bypass(editor->audio_engine, editor->track, editor->selected_slot, !bypassed);
                update_effects_list(editor);
            }
            return TRUE;

        case GDK_KEY_Escape:
            // Close window
            gtk_window_close(GTK_WINDOW(editor->window));
            return TRUE;
    }

    return FALSE;
}

// Create the effects chain editor
EffectsChainEditor* effects_chain_editor_new(GtkWindow *parent, void *audio_engine, int track) {
    EffectsChainEditor *editor = malloc(sizeof(EffectsChainEditor));
    if (!editor) return NULL;

    memset(editor, 0, sizeof(EffectsChainEditor));
    editor->audio_engine = audio_engine;
    editor->track = track;
    editor->selected_slot = -1;

    // Create window (not modal - modal blocks dropdowns on macOS)
    editor->window = gtk_window_new();
    gtk_window_set_title(GTK_WINDOW(editor->window), get_editor_title(track));
    gtk_window_set_default_size(GTK_WINDOW(editor->window), 350, 400);
    gtk_window_set_resizable(GTK_WINDOW(editor->window), TRUE);

    if (parent) {
        gtk_window_set_transient_for(GTK_WINDOW(editor->window), parent);
    }

    // Handle close button - hide instead of destroy
    g_signal_connect(editor->window, "close-request", G_CALLBACK(on_window_close_request), editor);

    // Main container
    GtkWidget *main_box = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0);

    // Header with title and chain bypass
    GtkWidget *header_box = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 12);
    gtk_widget_set_margin_start(header_box, 16);
    gtk_widget_set_margin_end(header_box, 16);
    gtk_widget_set_margin_top(header_box, 12);
    gtk_widget_set_margin_bottom(header_box, 8);

    // Title label
    char title_markup[128];
    if (track < 0) {
        snprintf(title_markup, sizeof(title_markup),
            "<span foreground='" TOKYONIGHT_CYAN "' weight='bold' size='large'>Master Effects Chain</span>");
    } else {
        snprintf(title_markup, sizeof(title_markup),
            "<span foreground='" TOKYONIGHT_CYAN "' weight='bold' size='large'>Track %d Effects Chain</span>", track + 1);
    }
    GtkWidget *title_label = gtk_label_new(NULL);
    gtk_label_set_markup(GTK_LABEL(title_label), title_markup);
    gtk_widget_set_hexpand(title_label, TRUE);
    gtk_widget_set_halign(title_label, GTK_ALIGN_START);
    gtk_box_append(GTK_BOX(header_box), title_label);

    // Chain bypass checkbox
    editor->chain_bypass_check = gtk_check_button_new_with_label("Bypass All");
    g_signal_connect(editor->chain_bypass_check, "toggled", G_CALLBACK(on_bypass_toggled), editor);
    gtk_box_append(GTK_BOX(header_box), editor->chain_bypass_check);

    gtk_box_append(GTK_BOX(main_box), header_box);

    // Separator
    GtkWidget *sep1 = gtk_separator_new(GTK_ORIENTATION_HORIZONTAL);
    gtk_box_append(GTK_BOX(main_box), sep1);

    // Hint label
    GtkWidget *hint_label = gtk_label_new("Double-click or press Edit to open effect controls");
    gtk_widget_set_opacity(hint_label, 0.6);
    gtk_widget_set_margin_start(hint_label, 12);
    gtk_widget_set_margin_top(hint_label, 8);
    gtk_widget_set_halign(hint_label, GTK_ALIGN_START);
    gtk_box_append(GTK_BOX(main_box), hint_label);

    // Scrolled list
    GtkWidget *scroll = gtk_scrolled_window_new();
    gtk_scrolled_window_set_policy(GTK_SCROLLED_WINDOW(scroll), GTK_POLICY_NEVER, GTK_POLICY_AUTOMATIC);
    gtk_widget_set_vexpand(scroll, TRUE);
    gtk_widget_set_margin_start(scroll, 8);
    gtk_widget_set_margin_end(scroll, 8);
    gtk_widget_set_margin_top(scroll, 8);

    // List box
    editor->effects_list_box = gtk_list_box_new();
    gtk_list_box_set_selection_mode(GTK_LIST_BOX(editor->effects_list_box), GTK_SELECTION_SINGLE);
    // Double-click opens effect modal
    g_signal_connect(editor->effects_list_box, "row-activated", G_CALLBACK(on_row_activated), editor);
    gtk_scrolled_window_set_child(GTK_SCROLLED_WINDOW(scroll), editor->effects_list_box);

    // "No effects" placeholder
    editor->no_effects_label = gtk_label_new("No effects in chain.\nUse dropdown below to add effects.");
    gtk_widget_set_margin_top(editor->no_effects_label, 20);
    gtk_widget_set_opacity(editor->no_effects_label, 0.6);
    gtk_box_append(GTK_BOX(main_box), editor->no_effects_label);

    gtk_box_append(GTK_BOX(main_box), scroll);

    // Add effect dropdown
    GtkWidget *add_box = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8);
    gtk_widget_set_margin_start(add_box, 12);
    gtk_widget_set_margin_end(add_box, 12);
    gtk_widget_set_margin_top(add_box, 8);
    gtk_widget_set_margin_bottom(add_box, 12);

    // Build effect type list
    int type_count = get_effect_type_count();
    char **type_names = malloc((type_count + 2) * sizeof(char *));
    type_names[0] = g_strdup("+ Add Effect...");
    for (int i = 0; i < type_count; i++) {
        type_names[i + 1] = g_strdup(get_effect_type_name(i));
    }
    type_names[type_count + 1] = NULL;

    editor->add_dropdown = gtk_drop_down_new_from_strings((const char * const *)type_names);
    gtk_widget_set_hexpand(editor->add_dropdown, TRUE);
    g_signal_connect(editor->add_dropdown, "notify::selected", G_CALLBACK(on_add_effect), editor);

    // Free temp strings
    for (int i = 0; i <= type_count; i++) {
        g_free(type_names[i]);
    }
    free(type_names);

    gtk_box_append(GTK_BOX(add_box), editor->add_dropdown);
    gtk_box_append(GTK_BOX(main_box), add_box);

    gtk_window_set_child(GTK_WINDOW(editor->window), main_box);

    // Keyboard controller
    GtkEventController *key_controller = gtk_event_controller_key_new();
    g_signal_connect(key_controller, "key-pressed", G_CALLBACK(on_key_pressed), editor);
    gtk_widget_add_controller(editor->window, key_controller);

    // Initial update
    update_effects_list(editor);

    return editor;
}

void effects_chain_editor_show(EffectsChainEditor *editor) {
    if (editor && editor->window) {
        // Refresh before showing
        update_effects_list(editor);
        gtk_window_present(GTK_WINDOW(editor->window));
    }
}

void effects_chain_editor_hide(EffectsChainEditor *editor) {
    if (editor && editor->window) {
        gtk_widget_set_visible(editor->window, FALSE);
    }
}

void effects_chain_editor_destroy(EffectsChainEditor *editor) {
    if (editor) {
        // Close all open effect modals
        for (int i = 0; i < editor->modal_count; i++) {
            if (editor->open_modals[i]) {
                effect_modal_destroy(editor->open_modals[i]);
            }
        }
        editor->modal_count = 0;

        if (editor->window) {
            gtk_window_destroy(GTK_WINDOW(editor->window));
        }
        free(editor);
    }
}

void effects_chain_editor_refresh(EffectsChainEditor *editor) {
    if (editor) {
        update_effects_list(editor);
    }
}
