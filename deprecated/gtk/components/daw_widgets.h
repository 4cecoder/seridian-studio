/**
 * DAW Widgets - Reusable UI Components Library
 *
 * Provides consistent, themed widgets for the DAW interface:
 * - Knobs (rotary controls for parameters)
 * - Vertical sliders (faders for volume/levels)
 * - Horizontal sliders (for frequency/time parameters)
 * - Value displays with units
 *
 * All widgets follow Tokyo Night color scheme and DAW conventions.
 */

#ifndef DAW_WIDGETS_H
#define DAW_WIDGETS_H

#include <gtk/gtk.h>
#include <stdbool.h>
#include <math.h>

// =============================================================================
// Color Theme (Tokyo Night)
// =============================================================================

#define DAW_COLOR_BG           "#1a1b26"
#define DAW_COLOR_BG_DARK      "#16161e"
#define DAW_COLOR_BG_HIGHLIGHT "#292e42"
#define DAW_COLOR_FG           "#c0caf5"
#define DAW_COLOR_FG_DARK      "#a9b1d6"
#define DAW_COLOR_COMMENT      "#565f89"
#define DAW_COLOR_CYAN         "#7dcfff"
#define DAW_COLOR_GREEN        "#9ece6a"
#define DAW_COLOR_ORANGE       "#ff9e64"
#define DAW_COLOR_PURPLE       "#bb9af7"
#define DAW_COLOR_RED          "#f7768e"
#define DAW_COLOR_YELLOW       "#e0af68"
#define DAW_COLOR_BLUE         "#7aa2f7"

// RGB values for Cairo
#define DAW_RGB_BG           0.10, 0.11, 0.15
#define DAW_RGB_BG_DARK      0.09, 0.09, 0.12
#define DAW_RGB_BG_HIGHLIGHT 0.16, 0.18, 0.26
#define DAW_RGB_FG           0.75, 0.79, 0.96
#define DAW_RGB_FG_DARK      0.66, 0.69, 0.84
#define DAW_RGB_ACCENT       0.48, 0.64, 0.97
#define DAW_RGB_ACCENT_DIM   0.34, 0.37, 0.53

// =============================================================================
// Widget Dimensions
// =============================================================================

#define DAW_KNOB_SIZE        60
#define DAW_KNOB_RADIUS      24
#define DAW_KNOB_LINE_WIDTH  3.0

#define DAW_SMALL_KNOB_SIZE        40
#define DAW_SMALL_KNOB_RADIUS      16
#define DAW_SMALL_KNOB_LINE_WIDTH  2.0

#define DAW_VSLIDER_WIDTH    40
#define DAW_VSLIDER_HEIGHT   100

#define DAW_HSLIDER_WIDTH    200
#define DAW_HSLIDER_HEIGHT   32

// =============================================================================
// Callback Types
// =============================================================================

typedef void (*DawValueChangedCallback)(float value, int param_index, void *user_data);

// =============================================================================
// Knob Widget
// =============================================================================

typedef struct {
    GtkWidget *container;      // Outer container (GtkBox)
    GtkWidget *drawing_area;   // Cairo drawing surface
    GtkWidget *label;          // Parameter name
    GtkWidget *value_label;    // Current value display

    float value;
    float min;
    float max;
    float default_value;

    int param_index;
    const char *unit;

    DawValueChangedCallback on_change;
    void *user_data;

    // Internal state
    float drag_start_value;
    bool is_dragging;
} DawKnob;

/**
 * Create a new knob widget
 *
 * @param name       Parameter display name
 * @param value      Initial value
 * @param min        Minimum value
 * @param max        Maximum value
 * @param unit       Unit string (e.g., "%", "Hz", "ms") or NULL
 * @param param_index Index for callback identification
 * @param on_change  Callback when value changes
 * @param user_data  User data for callback
 * @return Container widget (add this to your layout)
 */
GtkWidget* daw_knob_new(const char *name, float value, float min, float max,
                        const char *unit, int param_index,
                        DawValueChangedCallback on_change, void *user_data);

/**
 * Get the current value of a knob
 */
float daw_knob_get_value(GtkWidget *knob_container);

/**
 * Set the value of a knob (updates display)
 */
void daw_knob_set_value(GtkWidget *knob_container, float value);

/**
 * Reset knob to default value
 */
void daw_knob_reset(GtkWidget *knob_container);

/**
 * Create a small knob widget (40x40px) - for compact layouts
 * Same interface as daw_knob_new but smaller for ADSR, ratio controls, etc.
 */
GtkWidget* daw_small_knob_new(const char *name, float value, float min, float max,
                               const char *unit, int param_index,
                               DawValueChangedCallback on_change, void *user_data);

// =============================================================================
// Vertical Slider (Fader)
// =============================================================================

typedef struct {
    GtkWidget *container;
    GtkWidget *slider;
    GtkWidget *label;
    GtkWidget *value_label;

    float min;
    float max;
    int param_index;
    const char *unit;

    DawValueChangedCallback on_change;
    void *user_data;
} DawVSlider;

/**
 * Create a new vertical slider (fader)
 */
GtkWidget* daw_vslider_new(const char *name, float value, float min, float max,
                           const char *unit, int param_index,
                           DawValueChangedCallback on_change, void *user_data);

float daw_vslider_get_value(GtkWidget *slider_container);
void daw_vslider_set_value(GtkWidget *slider_container, float value);

// =============================================================================
// Horizontal Slider
// =============================================================================

typedef struct {
    GtkWidget *container;
    GtkWidget *slider;
    GtkWidget *label;
    GtkWidget *value_label;

    float min;
    float max;
    int param_index;
    const char *unit;

    DawValueChangedCallback on_change;
    void *user_data;
} DawHSlider;

/**
 * Create a new horizontal slider
 */
GtkWidget* daw_hslider_new(const char *name, float value, float min, float max,
                           const char *unit, int param_index,
                           DawValueChangedCallback on_change, void *user_data);

float daw_hslider_get_value(GtkWidget *slider_container);
void daw_hslider_set_value(GtkWidget *slider_container, float value);

// =============================================================================
// Utility Functions
// =============================================================================

/**
 * Format a value with appropriate precision and unit
 */
void daw_format_value(char *buffer, size_t size, float value, float min, float max, const char *unit);

/**
 * Determine best widget type for a parameter
 */
typedef enum {
    DAW_WIDGET_KNOB,
    DAW_WIDGET_VSLIDER,
    DAW_WIDGET_HSLIDER
} DawWidgetType;

DawWidgetType daw_suggest_widget_type(const char *param_name, float min, float max);

/**
 * Create the appropriate widget based on parameter characteristics
 */
GtkWidget* daw_param_widget_new(const char *name, float value, float min, float max,
                                const char *unit, int param_index,
                                DawValueChangedCallback on_change, void *user_data);

// =============================================================================
// Layout Helpers
// =============================================================================

/**
 * Set all four margins on a widget
 */
void daw_set_margins(GtkWidget *widget, int start, int end, int top, int bottom);

/**
 * Set uniform margins on all sides
 */
void daw_set_margin(GtkWidget *widget, int margin);

/**
 * Set horizontal margins (start and end)
 */
void daw_set_margins_h(GtkWidget *widget, int margin);

/**
 * Set vertical margins (top and bottom)
 */
void daw_set_margins_v(GtkWidget *widget, int margin);

// =============================================================================
// Section & Separator Builders
// =============================================================================

/**
 * Create a bold section header label
 */
GtkWidget* daw_section_header(const char *title);

/**
 * Create a horizontal separator with vertical margins
 */
GtkWidget* daw_separator(int margin_v);

/**
 * Create a frame with title and content box
 * Returns the content box for adding widgets
 */
GtkWidget* daw_frame_new(const char *title, GtkWidget **out_frame);

// =============================================================================
// Labeled Control Factories
// =============================================================================

/**
 * Create a row with label and dropdown
 * @param label_text    Label text
 * @param items         NULL-terminated array of option strings
 * @param selected      Index of initially selected item
 * @param out_dropdown  Output pointer to access the dropdown widget
 * @return The container box widget
 */
GtkWidget* daw_labeled_dropdown(const char *label_text, const char **items,
                                 int selected, GtkWidget **out_dropdown);

/**
 * Create a row with label and switch
 * @param label_text   Label text
 * @param active       Initial state
 * @param out_switch   Output pointer to access the switch widget
 * @return The container box widget
 */
GtkWidget* daw_labeled_switch(const char *label_text, gboolean active,
                               GtkWidget **out_switch);

/**
 * Create a row with label and spin button
 * @param label_text   Label text
 * @param value        Initial value
 * @param min          Minimum value
 * @param max          Maximum value
 * @param step         Step increment
 * @param out_spinner  Output pointer to access the spin button widget
 * @return The container box widget
 */
GtkWidget* daw_labeled_spinner(const char *label_text, double value,
                                double min, double max, double step,
                                GtkWidget **out_spinner);

/**
 * Create an info row with label and styled value
 * @param label_text  Label text
 * @param value_text  Value text (will be styled with accent color)
 * @return The container box widget
 */
GtkWidget* daw_info_row(const char *label_text, const char *value_text);

// =============================================================================
// Modal Helpers
// =============================================================================

/**
 * Standard modal close handler - hides instead of destroying
 * Use: g_signal_connect(window, "close-request", G_CALLBACK(daw_modal_close_handler), NULL);
 */
gboolean daw_modal_close_handler(GtkWindow *window, gpointer user_data);

/**
 * Create a standard modal window
 * @param parent       Parent window (can be NULL)
 * @param title        Window title
 * @param width        Default width
 * @param height       Default height
 * @param resizable    Whether window is resizable
 * @return The modal window widget
 */
GtkWidget* daw_modal_new(GtkWindow *parent, const char *title,
                          int width, int height, gboolean resizable);

/**
 * Create a standard header box for modals
 * @param title_markup  Pango markup for title (e.g., "<span weight='bold'>Title</span>")
 * @return The header box widget
 */
GtkWidget* daw_modal_header(const char *title_markup);

// =============================================================================
// Button Factories
// =============================================================================

/**
 * Create an icon button (for toolbars, list items)
 * @param icon_text  Unicode icon or short text
 * @param tooltip    Tooltip text
 * @param size       Button size (-1 for default)
 * @return The button widget
 */
GtkWidget* daw_icon_button(const char *icon_text, const char *tooltip, int size);

/**
 * Create a destructive (red) action button
 */
GtkWidget* daw_destructive_button(const char *icon_text, const char *tooltip, int size);

// =============================================================================
// Transport Button Factories
// =============================================================================

/**
 * Create a transport button (play, stop, record, etc.)
 * These are minimal icon-only buttons with no borders/background.
 * @param icon       Unicode icon (e.g., "▶", "⏸", "⏹", "⏺")
 * @param tooltip    Tooltip text
 * @param color      CSS color for the icon (e.g., DAW_COLOR_GREEN), NULL for default
 * @return The button widget
 */
GtkWidget* daw_transport_button(const char *icon, const char *tooltip, const char *color);

/**
 * Update a transport button's icon and optionally color
 * @param button     The transport button widget
 * @param icon       New icon
 * @param color      New color (NULL to keep current)
 */
void daw_transport_button_set_icon(GtkWidget *button, const char *icon, const char *color);

// =============================================================================
// Session Menu (Modern Popover Dropdown)
// =============================================================================

/**
 * Callback types for session menu actions
 */
typedef void (*DawSessionCallback)(void *user_data);

/**
 * Session menu configuration
 */
typedef struct {
    DawSessionCallback on_new;
    DawSessionCallback on_open;
    DawSessionCallback on_save;
    DawSessionCallback on_save_as;
    DawSessionCallback on_export_audio;
    DawSessionCallback on_export_midi;
    DawSessionCallback on_import;
    void *user_data;
} DawSessionMenuCallbacks;

/**
 * Create a modern session menu button with popover
 * Features:
 * - Flat icon-only trigger button
 * - Sliding popover with organized sections
 * - Icons and keyboard shortcut hints
 * - Tokyo Night themed
 *
 * @param callbacks  Struct with action callbacks
 * @return The menu button widget
 */
GtkWidget* daw_session_menu_new(DawSessionMenuCallbacks *callbacks);

/**
 * Update recent files in session menu
 * @param menu_button  The session menu button
 * @param paths        Array of recent file paths
 * @param count        Number of paths
 */
void daw_session_menu_set_recent(GtkWidget *menu_button, const char **paths, int count);

#endif // DAW_WIDGETS_H
