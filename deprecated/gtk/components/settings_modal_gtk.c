#include "settings_modal_gtk.h"
#include "daw_widgets.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

// Use shared color scheme from daw_widgets.h
#define TOKYONIGHT_COMMENT DAW_COLOR_COMMENT
#define TOKYONIGHT_CYAN    DAW_COLOR_CYAN
#define TOKYONIGHT_ORANGE  DAW_COLOR_ORANGE

// Modal size constants
#define MODAL_WIDTH 900
#define MODAL_HEIGHT 600
#define SIDEBAR_WIDTH 200

// Category enumeration
typedef enum {
    CATEGORY_SYSTEM = 0,
    CATEGORY_AUDIO,
    CATEGORY_DISPLAY,
    CATEGORY_GRAPHICS,
    CATEGORY_MIDI,
    CATEGORY_PERFORMANCE,
    CATEGORY_APPEARANCE,
    CATEGORY_PROJECT,
    CATEGORY_FILE_FOLDERS,
    CATEGORY_PLUGINS,
    CATEGORY_ADVANCED,
    CATEGORY_COUNT
} SettingsCategory;

// Category names
static const char* CATEGORY_NAMES[CATEGORY_COUNT] = {
    "System",
    "Audio",
    "Display",
    "Graphics",
    "MIDI",
    "Performance",
    "Appearance",
    "Project",
    "File/Folders",
    "Plugins",
    "Advanced"
};

// Categories that require restart
static const gboolean CATEGORY_REQUIRES_RESTART[CATEGORY_COUNT] = {
    FALSE,  // System (info only)
    TRUE,   // Audio
    TRUE,   // Display
    TRUE,   // Graphics
    FALSE,  // MIDI
    TRUE,   // Performance
    FALSE,  // Appearance
    FALSE,  // Project
    FALSE,  // File/Folders
    FALSE,  // Plugins
    FALSE   // Advanced
};

struct SettingsModal {
    GtkWidget *window;
    GtkWidget *sidebar;
    GtkWidget *stack;
    GtkWidget *restart_warning;
    GtkWidget *apply_button;
    GtkWidget *cancel_button;
    GtkWidget *reset_button;

    // Sidebar buttons for highlighting
    GtkWidget *category_buttons[CATEGORY_COUNT];

    // Current category
    SettingsCategory current_category;

    // Callbacks
    SettingsApplyCallback apply_callback;
    void *apply_user_data;
    SettingsCancelCallback cancel_callback;
    void *cancel_user_data;
    SettingsResetCallback reset_callback;
    void *reset_user_data;

    // Dirty flag
    gboolean has_changes;
};

// Forward declarations
static void on_category_clicked(GtkButton *button, gpointer user_data);
static void on_apply_clicked(GtkButton *button, gpointer user_data);
static void on_cancel_clicked(GtkButton *button, gpointer user_data);
static void on_reset_clicked(GtkButton *button, gpointer user_data);
static void update_restart_warning(SettingsModal *modal);
static GtkWidget* create_system_panel(SettingsModal *modal);
static GtkWidget* create_audio_panel(SettingsModal *modal);
static GtkWidget* create_display_panel(SettingsModal *modal);
static GtkWidget* create_graphics_panel(SettingsModal *modal);
static GtkWidget* create_midi_panel(SettingsModal *modal);
static GtkWidget* create_performance_panel(SettingsModal *modal);
static GtkWidget* create_appearance_panel(SettingsModal *modal);
static GtkWidget* create_project_panel(SettingsModal *modal);
static GtkWidget* create_file_folders_panel(SettingsModal *modal);
static GtkWidget* create_plugins_panel(SettingsModal *modal);
static GtkWidget* create_advanced_panel(SettingsModal *modal);

// Use shared widget factories from daw_widgets.h:
// - daw_labeled_dropdown(label, items, selected, out_dropdown)
// - daw_labeled_spinner(label, value, min, max, step, out_spinner)
// - daw_labeled_switch(label, active, out_switch)
// - daw_info_row(label, value)
// - daw_section_header(title)
// - daw_separator(margin_v)

// Compatibility wrappers for existing code (to be refactored incrementally)
static GtkWidget* create_labeled_dropdown(const char *label_text, const char **items, int item_count) {
    (void)item_count;  // items must be NULL-terminated
    return daw_labeled_dropdown(label_text, items, 0, NULL);
}

static GtkWidget* create_labeled_spinner(const char *label_text, double min, double max, double step, double value) {
    return daw_labeled_spinner(label_text, value, min, max, step, NULL);
}

static GtkWidget* create_labeled_switch(const char *label_text, gboolean active) {
    return daw_labeled_switch(label_text, active, NULL);
}

// Helper function to create placeholder panel
static GtkWidget* create_placeholder_panel(const char *category_name) {
    GtkWidget *box = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0);
    daw_set_margin(box, 24);

    GtkWidget *label = gtk_label_new(NULL);
    char markup[256];
    snprintf(markup, sizeof(markup), "<span size='large' weight='bold'>%s Settings</span>\n\n<span foreground='%s'>Coming Soon</span>",
             category_name, TOKYONIGHT_COMMENT);
    gtk_label_set_markup(GTK_LABEL(label), markup);
    gtk_label_set_justify(GTK_LABEL(label), GTK_JUSTIFY_CENTER);
    gtk_widget_set_valign(label, GTK_ALIGN_CENTER);
    gtk_widget_set_halign(label, GTK_ALIGN_CENTER);
    gtk_widget_set_vexpand(label, TRUE);

    gtk_box_append(GTK_BOX(box), label);

    return box;
}

// Use shared daw_info_row from daw_widgets.h
#define create_info_row daw_info_row

// System panel implementation - shows detected system capabilities
static GtkWidget* create_system_panel(SettingsModal *modal) {
    (void)modal;

    GtkWidget *scrolled = gtk_scrolled_window_new();
    gtk_scrolled_window_set_policy(GTK_SCROLLED_WINDOW(scrolled),
                                   GTK_POLICY_NEVER, GTK_POLICY_AUTOMATIC);

    GtkWidget *box = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0);
    daw_set_margin(box, 24);

    // Get system info from Zig
    SystemInfo info = system_get_info();

    // Title
    GtkWidget *title = gtk_label_new(NULL);
    gtk_label_set_markup(GTK_LABEL(title), "<span size='large' weight='bold'>System Information</span>");
    gtk_widget_set_halign(title, GTK_ALIGN_START);
    gtk_widget_set_margin_bottom(title, 16);
    gtk_box_append(GTK_BOX(box), title);

    // Description
    GtkWidget *desc = gtk_label_new(NULL);
    gtk_label_set_markup(GTK_LABEL(desc),
        "<span foreground='" TOKYONIGHT_COMMENT "'>Detected system capabilities and configuration.</span>");
    gtk_widget_set_halign(desc, GTK_ALIGN_START);
    gtk_widget_set_margin_bottom(desc, 16);
    gtk_box_append(GTK_BOX(box), desc);

    // Platform Section
    gtk_box_append(GTK_BOX(box), daw_section_header("Platform"));
    gtk_box_append(GTK_BOX(box), create_info_row("Operating System:", info.os_name));
    gtk_box_append(GTK_BOX(box), create_info_row("Architecture:", info.arch));
    gtk_box_append(GTK_BOX(box), daw_separator(12));

    // Audio Section
    gtk_box_append(GTK_BOX(box), daw_section_header("Audio"));
    gtk_box_append(GTK_BOX(box), create_info_row("Backend:", info.audio_backend));

    char rate_str[32];
    snprintf(rate_str, sizeof(rate_str), "%u Hz", info.sample_rate);
    gtk_box_append(GTK_BOX(box), create_info_row("Default Sample Rate:", rate_str));

    char buffer_str[32];
    snprintf(buffer_str, sizeof(buffer_str), "%u samples", info.buffer_size);
    gtk_box_append(GTK_BOX(box), create_info_row("Default Buffer Size:", buffer_str));
    gtk_box_append(GTK_BOX(box), daw_separator(12));

    // MIDI Section
    gtk_box_append(GTK_BOX(box), daw_section_header("MIDI"));
    gtk_box_append(GTK_BOX(box), create_info_row("Backend:", info.midi_backend));

    char midi_in_str[32];
    snprintf(midi_in_str, sizeof(midi_in_str), "%u", info.midi_inputs);
    gtk_box_append(GTK_BOX(box), create_info_row("Input Devices:", midi_in_str));

    char midi_out_str[32];
    snprintf(midi_out_str, sizeof(midi_out_str), "%u", info.midi_outputs);
    gtk_box_append(GTK_BOX(box), create_info_row("Output Devices:", midi_out_str));
    gtk_box_append(GTK_BOX(box), daw_separator(12));

    // Hardware Section
    gtk_box_append(GTK_BOX(box), daw_section_header("Hardware"));

    char cores_str[32];
    snprintf(cores_str, sizeof(cores_str), "%u", info.cpu_cores);
    gtk_box_append(GTK_BOX(box), create_info_row("CPU Cores:", cores_str));

    char threads_str[32];
    snprintf(threads_str, sizeof(threads_str), "%u", info.recommended_threads);
    gtk_box_append(GTK_BOX(box), create_info_row("Recommended Threads:", threads_str));

    gtk_box_append(GTK_BOX(box), create_info_row("GPU Acceleration:",
        info.has_gpu_acceleration ? "Available" : "Not Available"));

    char scale_str[32];
    snprintf(scale_str, sizeof(scale_str), "%.1fx", info.display_scale);
    gtk_box_append(GTK_BOX(box), create_info_row("Display Scale:", scale_str));

    // Info footer
    GtkWidget *footer = gtk_label_new(NULL);
    gtk_label_set_markup(GTK_LABEL(footer),
        "<span foreground='" TOKYONIGHT_COMMENT "' size='small'>"
        "System capabilities are detected at startup and used to configure optimal defaults."
        "</span>");
    gtk_label_set_wrap(GTK_LABEL(footer), TRUE);
    gtk_widget_set_halign(footer, GTK_ALIGN_START);
    gtk_widget_set_margin_top(footer, 24);
    gtk_box_append(GTK_BOX(box), footer);

    gtk_scrolled_window_set_child(GTK_SCROLLED_WINDOW(scrolled), box);
    return scrolled;
}

// Audio panel implementation - uses dynamically detected backends and devices
static GtkWidget* create_audio_panel(SettingsModal *modal) {
    (void)modal;

    GtkWidget *scrolled = gtk_scrolled_window_new();
    gtk_scrolled_window_set_policy(GTK_SCROLLED_WINDOW(scrolled),
                                   GTK_POLICY_NEVER, GTK_POLICY_AUTOMATIC);

    GtkWidget *box = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0);
    gtk_widget_set_margin_start(box, 24);
    gtk_widget_set_margin_end(box, 24);
    gtk_widget_set_margin_top(box, 24);
    gtk_widget_set_margin_bottom(box, 24);

    // Title
    GtkWidget *title = gtk_label_new(NULL);
    gtk_label_set_markup(GTK_LABEL(title), "<span size='large' weight='bold'>Audio Settings</span>");
    gtk_widget_set_halign(title, GTK_ALIGN_START);
    gtk_widget_set_margin_bottom(title, 16);
    gtk_box_append(GTK_BOX(box), title);

    // Description
    GtkWidget *desc = gtk_label_new(NULL);
    gtk_label_set_markup(GTK_LABEL(desc),
        "<span foreground='" TOKYONIGHT_COMMENT "'>Configure audio interface and device settings.</span>");
    gtk_widget_set_halign(desc, GTK_ALIGN_START);
    gtk_widget_set_margin_bottom(desc, 16);
    gtk_box_append(GTK_BOX(box), desc);

    // ========== Detected Devices Section ==========
    GtkWidget *detected_label = gtk_label_new(NULL);
    gtk_label_set_markup(GTK_LABEL(detected_label), "<span weight='bold'>Detected Audio Hardware</span>");
    gtk_widget_set_halign(detected_label, GTK_ALIGN_START);
    gtk_widget_set_margin_bottom(detected_label, 8);
    gtk_box_append(GTK_BOX(box), detected_label);

    // Get device counts
    uint32_t input_count = system_get_input_device_count();
    uint32_t output_count = system_get_output_device_count();

    char input_count_str[32];
    snprintf(input_count_str, sizeof(input_count_str), "%u device%s", input_count, input_count == 1 ? "" : "s");
    gtk_box_append(GTK_BOX(box), create_info_row("Input Devices:", input_count_str));

    char output_count_str[32];
    snprintf(output_count_str, sizeof(output_count_str), "%u device%s", output_count, output_count == 1 ? "" : "s");
    gtk_box_append(GTK_BOX(box), create_info_row("Output Devices:", output_count_str));

    // Separator
    GtkWidget *sep0 = gtk_separator_new(GTK_ORIENTATION_HORIZONTAL);
    gtk_widget_set_margin_top(sep0, 12);
    gtk_widget_set_margin_bottom(sep0, 12);
    gtk_box_append(GTK_BOX(box), sep0);

    // ========== Backend Settings ==========
    GtkWidget *backend_label = gtk_label_new(NULL);
    gtk_label_set_markup(GTK_LABEL(backend_label), "<span weight='bold'>Audio Backend</span>");
    gtk_widget_set_halign(backend_label, GTK_ALIGN_START);
    gtk_widget_set_margin_bottom(backend_label, 8);
    gtk_box_append(GTK_BOX(box), backend_label);

    // Get dynamically detected audio backends
    AudioBackendList backends = system_get_available_audio_backends();
    static const char *backend_ptrs[MAX_BACKENDS + 1];
    for (uint32_t i = 0; i < backends.count && i < MAX_BACKENDS; i++) {
        backend_ptrs[i] = backends.names[i];
    }
    backend_ptrs[backends.count] = NULL;

    GtkWidget *backend_row = create_labeled_dropdown("Audio Backend:", backend_ptrs, (int)backends.count);
    gtk_box_append(GTK_BOX(box), backend_row);

    // Get dynamically detected sample rates
    SampleRateList rates = system_get_available_sample_rates();
    static char rate_strs[8][32];
    static const char *rate_ptrs[9];
    for (uint32_t i = 0; i < rates.count && i < 8; i++) {
        snprintf(rate_strs[i], sizeof(rate_strs[i]), "%u Hz", rates.rates[i]);
        rate_ptrs[i] = rate_strs[i];
    }
    rate_ptrs[rates.count] = NULL;

    GtkWidget *rate_row = create_labeled_dropdown("Sample Rate:", rate_ptrs, (int)rates.count);
    gtk_box_append(GTK_BOX(box), rate_row);

    // Get dynamically detected buffer sizes
    BufferSizeList sizes = system_get_available_buffer_sizes();
    static char size_strs[8][32];
    static const char *size_ptrs[9];
    for (uint32_t i = 0; i < sizes.count && i < 8; i++) {
        snprintf(size_strs[i], sizeof(size_strs[i]), "%u samples", sizes.sizes[i]);
        size_ptrs[i] = size_strs[i];
    }
    size_ptrs[sizes.count] = NULL;

    GtkWidget *buffer_row = create_labeled_dropdown("Buffer Size:", size_ptrs, (int)sizes.count);
    gtk_box_append(GTK_BOX(box), buffer_row);

    // Latency info
    SystemInfo info = system_get_info();
    float latency_ms = (float)info.buffer_size / (float)info.sample_rate * 1000.0f;
    char latency_str[64];
    snprintf(latency_str, sizeof(latency_str), "%.1f ms (at %u Hz)", latency_ms, info.sample_rate);
    gtk_box_append(GTK_BOX(box), create_info_row("Est. Latency:", latency_str));

    // Separator
    GtkWidget *sep1 = gtk_separator_new(GTK_ORIENTATION_HORIZONTAL);
    gtk_widget_set_margin_top(sep1, 12);
    gtk_widget_set_margin_bottom(sep1, 12);
    gtk_box_append(GTK_BOX(box), sep1);

    // ========== Device Selection ==========
    GtkWidget *device_label = gtk_label_new(NULL);
    gtk_label_set_markup(GTK_LABEL(device_label), "<span weight='bold'>Device Selection</span>");
    gtk_widget_set_halign(device_label, GTK_ALIGN_START);
    gtk_widget_set_margin_bottom(device_label, 8);
    gtk_box_append(GTK_BOX(box), device_label);

    // Build input device list dynamically with real names
    static char input_device_strs[16][128];
    static const char *input_device_ptrs[17];
    input_device_ptrs[0] = "System Default";
    uint32_t input_idx = 1;
    for (uint32_t i = 0; i < input_count && i < 15; i++) {
        const char *name = system_get_input_device_name(i);
        snprintf(input_device_strs[i], sizeof(input_device_strs[i]), "%s", name);
        input_device_ptrs[input_idx++] = input_device_strs[i];
    }
    input_device_ptrs[input_idx] = NULL;

    GtkWidget *input_row = create_labeled_dropdown("Input Device:", input_device_ptrs, (int)input_idx);
    gtk_box_append(GTK_BOX(box), input_row);

    // Build output device list dynamically with real names
    static char output_device_strs[16][128];
    static const char *output_device_ptrs[17];
    output_device_ptrs[0] = "System Default";
    uint32_t output_idx = 1;
    for (uint32_t i = 0; i < output_count && i < 15; i++) {
        const char *name = system_get_output_device_name(i);
        snprintf(output_device_strs[i], sizeof(output_device_strs[i]), "%s", name);
        output_device_ptrs[output_idx++] = output_device_strs[i];
    }
    output_device_ptrs[output_idx] = NULL;

    GtkWidget *output_row = create_labeled_dropdown("Output Device:", output_device_ptrs, (int)output_idx);
    gtk_box_append(GTK_BOX(box), output_row);

    // Info footer
    GtkWidget *info_label = gtk_label_new(NULL);
    gtk_label_set_markup(GTK_LABEL(info_label),
        "<span foreground='" TOKYONIGHT_COMMENT "' size='small'>"
        "Note: Changes to audio settings require application restart. "
        "Lower buffer sizes reduce latency but increase CPU usage."
        "</span>");
    gtk_label_set_wrap(GTK_LABEL(info_label), TRUE);
    gtk_widget_set_halign(info_label, GTK_ALIGN_START);
    gtk_widget_set_margin_top(info_label, 16);
    gtk_box_append(GTK_BOX(box), info_label);

    gtk_scrolled_window_set_child(GTK_SCROLLED_WINDOW(scrolled), box);
    return scrolled;
}

// Display panel implementation - uses detected display capabilities
static GtkWidget* create_display_panel(SettingsModal *modal) {
    (void)modal;

    GtkWidget *scrolled = gtk_scrolled_window_new();
    gtk_scrolled_window_set_policy(GTK_SCROLLED_WINDOW(scrolled),
                                   GTK_POLICY_NEVER, GTK_POLICY_AUTOMATIC);

    GtkWidget *box = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0);
    gtk_widget_set_margin_start(box, 24);
    gtk_widget_set_margin_end(box, 24);
    gtk_widget_set_margin_top(box, 24);
    gtk_widget_set_margin_bottom(box, 24);

    // Title
    GtkWidget *title = gtk_label_new(NULL);
    gtk_label_set_markup(GTK_LABEL(title), "<span size='large' weight='bold'>Display Settings</span>");
    gtk_widget_set_halign(title, GTK_ALIGN_START);
    gtk_widget_set_margin_bottom(title, 16);
    gtk_box_append(GTK_BOX(box), title);

    // Description
    GtkWidget *desc = gtk_label_new(NULL);
    gtk_label_set_markup(GTK_LABEL(desc),
        "<span foreground='" TOKYONIGHT_COMMENT "'>Configure display and window settings.</span>");
    gtk_widget_set_halign(desc, GTK_ALIGN_START);
    gtk_widget_set_margin_bottom(desc, 16);
    gtk_box_append(GTK_BOX(box), desc);

    // ========== Detected Display Info ==========
    GtkWidget *detected_label = gtk_label_new(NULL);
    gtk_label_set_markup(GTK_LABEL(detected_label), "<span weight='bold'>Detected Display</span>");
    gtk_widget_set_halign(detected_label, GTK_ALIGN_START);
    gtk_widget_set_margin_bottom(detected_label, 8);
    gtk_box_append(GTK_BOX(box), detected_label);

    SystemInfo info = system_get_info();
    uint32_t refresh_rate = system_get_display_refresh_rate();

    char scale_str[32];
    snprintf(scale_str, sizeof(scale_str), "%.1fx", info.display_scale);
    gtk_box_append(GTK_BOX(box), create_info_row("Current Scale:", scale_str));

    char refresh_str[32];
    snprintf(refresh_str, sizeof(refresh_str), "%u Hz", refresh_rate);
    gtk_box_append(GTK_BOX(box), create_info_row("Refresh Rate:", refresh_str));

    // Separator
    GtkWidget *sep1 = gtk_separator_new(GTK_ORIENTATION_HORIZONTAL);
    gtk_widget_set_margin_top(sep1, 12);
    gtk_widget_set_margin_bottom(sep1, 12);
    gtk_box_append(GTK_BOX(box), sep1);

    // ========== Display Settings ==========
    GtkWidget *settings_label = gtk_label_new(NULL);
    gtk_label_set_markup(GTK_LABEL(settings_label), "<span weight='bold'>Window Settings</span>");
    gtk_widget_set_halign(settings_label, GTK_ALIGN_START);
    gtk_widget_set_margin_bottom(settings_label, 8);
    gtk_box_append(GTK_BOX(box), settings_label);

    // Fullscreen mode dropdown
    const char *fullscreen_modes[] = {"Windowed", "Fullscreen", "Borderless Window", NULL};
    GtkWidget *fullscreen_row = create_labeled_dropdown("Window Mode:", fullscreen_modes, 3);
    gtk_box_append(GTK_BOX(box), fullscreen_row);

    // Window scale spinner (default to detected scale)
    GtkWidget *scale_row = create_labeled_spinner("UI Scale:", 0.5, 3.0, 0.1, (double)info.display_scale);
    gtk_box_append(GTK_BOX(box), scale_row);

    // HiDPI switch
    GtkWidget *hidpi_row = create_labeled_switch("HiDPI Mode:", info.display_scale >= 2.0);
    gtk_box_append(GTK_BOX(box), hidpi_row);

    // Separator
    GtkWidget *sep2 = gtk_separator_new(GTK_ORIENTATION_HORIZONTAL);
    gtk_widget_set_margin_top(sep2, 12);
    gtk_widget_set_margin_bottom(sep2, 12);
    gtk_box_append(GTK_BOX(box), sep2);

    // ========== Advanced Display ==========
    GtkWidget *advanced_label = gtk_label_new(NULL);
    gtk_label_set_markup(GTK_LABEL(advanced_label), "<span weight='bold'>Advanced</span>");
    gtk_widget_set_halign(advanced_label, GTK_ALIGN_START);
    gtk_widget_set_margin_bottom(advanced_label, 8);
    gtk_box_append(GTK_BOX(box), advanced_label);

    // Display backend dropdown - platform-specific
    #ifdef __APPLE__
    const char *display_backends[] = {"Native (Cocoa)", NULL};
    int backend_count = 1;
    #else
    const char *display_backends[] = {"Auto", "Wayland", "X11", NULL};
    int backend_count = 3;
    #endif

    GtkWidget *backend_row = create_labeled_dropdown("Display Backend:", display_backends, backend_count);
    gtk_box_append(GTK_BOX(box), backend_row);

    // Info label
    GtkWidget *info_lbl = gtk_label_new(NULL);
    gtk_label_set_markup(GTK_LABEL(info_lbl),
        "<span foreground='" TOKYONIGHT_COMMENT "' size='small'>Note: Display backend changes require application restart.</span>");
    gtk_label_set_wrap(GTK_LABEL(info_lbl), TRUE);
    gtk_widget_set_halign(info_lbl, GTK_ALIGN_START);
    gtk_widget_set_margin_top(info_lbl, 16);
    gtk_box_append(GTK_BOX(box), info_lbl);

    gtk_scrolled_window_set_child(GTK_SCROLLED_WINDOW(scrolled), box);
    return scrolled;
}

// Graphics panel implementation - uses dynamically detected renderers
static GtkWidget* create_graphics_panel(SettingsModal *modal) {
    (void)modal;

    GtkWidget *scrolled = gtk_scrolled_window_new();
    gtk_scrolled_window_set_policy(GTK_SCROLLED_WINDOW(scrolled),
                                   GTK_POLICY_NEVER, GTK_POLICY_AUTOMATIC);

    GtkWidget *box = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0);
    gtk_widget_set_margin_start(box, 24);
    gtk_widget_set_margin_end(box, 24);
    gtk_widget_set_margin_top(box, 24);
    gtk_widget_set_margin_bottom(box, 24);

    // Title
    GtkWidget *title = gtk_label_new(NULL);
    gtk_label_set_markup(GTK_LABEL(title), "<span size='large' weight='bold'>Graphics Settings</span>");
    gtk_widget_set_halign(title, GTK_ALIGN_START);
    gtk_widget_set_margin_bottom(title, 16);
    gtk_box_append(GTK_BOX(box), title);

    // Description
    GtkWidget *desc = gtk_label_new(NULL);
    gtk_label_set_markup(GTK_LABEL(desc),
        "<span foreground='" TOKYONIGHT_COMMENT "'>Configure graphics rendering based on detected capabilities.</span>");
    gtk_widget_set_halign(desc, GTK_ALIGN_START);
    gtk_widget_set_margin_bottom(desc, 16);
    gtk_box_append(GTK_BOX(box), desc);

    // ========== GPU Info Section ==========
    GtkWidget *gpu_label = gtk_label_new(NULL);
    gtk_label_set_markup(GTK_LABEL(gpu_label), "<span weight='bold'>Detected GPU</span>");
    gtk_widget_set_halign(gpu_label, GTK_ALIGN_START);
    gtk_widget_set_margin_bottom(gpu_label, 8);
    gtk_box_append(GTK_BOX(box), gpu_label);

    const char *gpu_vendor = system_get_gpu_vendor();
    const char *gpu_name = system_get_gpu_name();
    uint32_t refresh_rate = system_get_display_refresh_rate();

    gtk_box_append(GTK_BOX(box), create_info_row("GPU Vendor:", gpu_vendor));
    gtk_box_append(GTK_BOX(box), create_info_row("GPU Name:", gpu_name));

    char refresh_str[32];
    snprintf(refresh_str, sizeof(refresh_str), "%u Hz", refresh_rate);
    gtk_box_append(GTK_BOX(box), create_info_row("Display Refresh:", refresh_str));

    // Separator
    GtkWidget *sep1 = gtk_separator_new(GTK_ORIENTATION_HORIZONTAL);
    gtk_widget_set_margin_top(sep1, 12);
    gtk_widget_set_margin_bottom(sep1, 12);
    gtk_box_append(GTK_BOX(box), sep1);

    // ========== Renderer Settings ==========
    GtkWidget *renderer_label = gtk_label_new(NULL);
    gtk_label_set_markup(GTK_LABEL(renderer_label), "<span weight='bold'>Renderer Settings</span>");
    gtk_widget_set_halign(renderer_label, GTK_ALIGN_START);
    gtk_widget_set_margin_bottom(renderer_label, 8);
    gtk_box_append(GTK_BOX(box), renderer_label);

    // Get dynamically detected renderers
    GraphicsRendererList renderers = system_get_available_renderers();
    static const char *renderer_ptrs[MAX_RENDERERS + 1];
    for (uint32_t i = 0; i < renderers.count && i < MAX_RENDERERS; i++) {
        renderer_ptrs[i] = renderers.names[i];
    }
    renderer_ptrs[renderers.count] = NULL;

    GtkWidget *renderer_row = create_labeled_dropdown("Renderer:", renderer_ptrs, (int)renderers.count);
    gtk_box_append(GTK_BOX(box), renderer_row);

    // VSync switch
    GtkWidget *vsync_row = create_labeled_switch("Enable VSync:", TRUE);
    gtk_box_append(GTK_BOX(box), vsync_row);

    // Max FPS spinner (default to refresh rate)
    GtkWidget *fps_row = create_labeled_spinner("Max FPS:", 30, 240, 1, (double)refresh_rate);
    gtk_box_append(GTK_BOX(box), fps_row);

    // Separator
    GtkWidget *sep2 = gtk_separator_new(GTK_ORIENTATION_HORIZONTAL);
    gtk_widget_set_margin_top(sep2, 12);
    gtk_widget_set_margin_bottom(sep2, 12);
    gtk_box_append(GTK_BOX(box), sep2);

    // ========== Advanced Options ==========
    GtkWidget *advanced_label = gtk_label_new(NULL);
    gtk_label_set_markup(GTK_LABEL(advanced_label), "<span weight='bold'>Advanced Options</span>");
    gtk_widget_set_halign(advanced_label, GTK_ALIGN_START);
    gtk_widget_set_margin_bottom(advanced_label, 8);
    gtk_box_append(GTK_BOX(box), advanced_label);

    // GPU acceleration switch (disabled if not available)
    SystemInfo info = system_get_info();
    GtkWidget *accel_row = create_labeled_switch("GPU Acceleration:", info.has_gpu_acceleration);
    gtk_box_append(GTK_BOX(box), accel_row);

    // Anti-aliasing dropdown
    const char *aa_options[] = {"None", "2x MSAA", "4x MSAA", "8x MSAA", NULL};
    GtkWidget *aa_row = create_labeled_dropdown("Anti-Aliasing:", aa_options, 4);
    gtk_box_append(GTK_BOX(box), aa_row);

    // Info label
    GtkWidget *info_lbl = gtk_label_new(NULL);
    gtk_label_set_markup(GTK_LABEL(info_lbl),
        "<span foreground='" TOKYONIGHT_COMMENT "' size='small'>Note: Renderer changes require application restart.</span>");
    gtk_label_set_wrap(GTK_LABEL(info_lbl), TRUE);
    gtk_widget_set_halign(info_lbl, GTK_ALIGN_START);
    gtk_widget_set_margin_top(info_lbl, 16);
    gtk_box_append(GTK_BOX(box), info_lbl);

    gtk_scrolled_window_set_child(GTK_SCROLLED_WINDOW(scrolled), box);
    return scrolled;
}

// MIDI panel (placeholder)
static GtkWidget* create_midi_panel(SettingsModal *modal) {
    (void)modal;
    return create_placeholder_panel("MIDI");
}

// Performance panel implementation
static GtkWidget* create_performance_panel(SettingsModal *modal) {
    (void)modal;

    GtkWidget *scrolled = gtk_scrolled_window_new();
    gtk_scrolled_window_set_policy(GTK_SCROLLED_WINDOW(scrolled),
                                   GTK_POLICY_NEVER, GTK_POLICY_AUTOMATIC);

    GtkWidget *box = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0);
    gtk_widget_set_margin_start(box, 24);
    gtk_widget_set_margin_end(box, 24);
    gtk_widget_set_margin_top(box, 24);
    gtk_widget_set_margin_bottom(box, 24);

    // Title
    GtkWidget *title = gtk_label_new(NULL);
    gtk_label_set_markup(GTK_LABEL(title), "<span size='large' weight='bold'>Performance Settings</span>");
    gtk_widget_set_halign(title, GTK_ALIGN_START);
    gtk_widget_set_margin_bottom(title, 16);
    gtk_box_append(GTK_BOX(box), title);

    // Redraw strategy dropdown
    const char *strategies[] = {"On Demand", "Continuous", "Adaptive", NULL};
    GtkWidget *strategy_row = create_labeled_dropdown("Redraw Strategy:", strategies, 3);
    gtk_box_append(GTK_BOX(box), strategy_row);

    // Culling switch
    GtkWidget *culling_row = create_labeled_switch("Enable Culling:", TRUE);
    gtk_box_append(GTK_BOX(box), culling_row);

    // Batching switch
    GtkWidget *batching_row = create_labeled_switch("Enable Batching:", TRUE);
    gtk_box_append(GTK_BOX(box), batching_row);

    // Thread count spinner
    GtkWidget *threads_row = create_labeled_spinner("Thread Count:", 1, 32, 1, 4);
    gtk_box_append(GTK_BOX(box), threads_row);

    // Info label
    GtkWidget *info = gtk_label_new(NULL);
    gtk_label_set_markup(GTK_LABEL(info),
        "<span foreground='" TOKYONIGHT_COMMENT "' size='small'>Note: Performance changes may require application restart.</span>");
    gtk_label_set_wrap(GTK_LABEL(info), TRUE);
    gtk_widget_set_halign(info, GTK_ALIGN_START);
    gtk_widget_set_margin_top(info, 16);
    gtk_box_append(GTK_BOX(box), info);

    gtk_scrolled_window_set_child(GTK_SCROLLED_WINDOW(scrolled), box);
    return scrolled;
}

// Appearance panel implementation
static GtkWidget* create_appearance_panel(SettingsModal *modal) {
    (void)modal;

    GtkWidget *scrolled = gtk_scrolled_window_new();
    gtk_scrolled_window_set_policy(GTK_SCROLLED_WINDOW(scrolled),
                                   GTK_POLICY_NEVER, GTK_POLICY_AUTOMATIC);

    GtkWidget *box = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0);
    gtk_widget_set_margin_start(box, 24);
    gtk_widget_set_margin_end(box, 24);
    gtk_widget_set_margin_top(box, 24);
    gtk_widget_set_margin_bottom(box, 24);

    // Title
    GtkWidget *title = gtk_label_new(NULL);
    gtk_label_set_markup(GTK_LABEL(title), "<span size='large' weight='bold'>Appearance Settings</span>");
    gtk_widget_set_halign(title, GTK_ALIGN_START);
    gtk_widget_set_margin_bottom(title, 16);
    gtk_box_append(GTK_BOX(box), title);

    // Theme dropdown
    const char *themes[] = {"Tokyo Night", "Dark", "Light", "Ableton Dark", NULL};
    GtkWidget *theme_row = create_labeled_dropdown("Theme:", themes, 4);
    gtk_box_append(GTK_BOX(box), theme_row);

    // UI scale spinner
    GtkWidget *ui_scale_row = create_labeled_spinner("UI Scale:", 0.5, 2.0, 0.1, 1.0);
    gtk_box_append(GTK_BOX(box), ui_scale_row);

    // Font size spinner
    GtkWidget *font_row = create_labeled_spinner("Font Size:", 8, 24, 1, 12);
    gtk_box_append(GTK_BOX(box), font_row);

    gtk_scrolled_window_set_child(GTK_SCROLLED_WINDOW(scrolled), box);
    return scrolled;
}

// Project panel implementation
static GtkWidget* create_project_panel(SettingsModal *modal) {
    (void)modal;

    GtkWidget *scrolled = gtk_scrolled_window_new();
    gtk_scrolled_window_set_policy(GTK_SCROLLED_WINDOW(scrolled),
                                   GTK_POLICY_NEVER, GTK_POLICY_AUTOMATIC);

    GtkWidget *box = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0);
    gtk_widget_set_margin_start(box, 24);
    gtk_widget_set_margin_end(box, 24);
    gtk_widget_set_margin_top(box, 24);
    gtk_widget_set_margin_bottom(box, 24);

    // Title
    GtkWidget *title = gtk_label_new(NULL);
    gtk_label_set_markup(GTK_LABEL(title), "<span size='large' weight='bold'>Project Settings</span>");
    gtk_widget_set_halign(title, GTK_ALIGN_START);
    gtk_widget_set_margin_bottom(title, 16);
    gtk_box_append(GTK_BOX(box), title);

    // Default BPM spinner
    GtkWidget *bpm_row = create_labeled_spinner("Default BPM:", 40, 300, 1, 120);
    gtk_box_append(GTK_BOX(box), bpm_row);

    // Time signature dropdown
    const char *time_sigs[] = {"4/4", "3/4", "6/8", "7/8", "5/4", NULL};
    GtkWidget *time_sig_row = create_labeled_dropdown("Time Signature:", time_sigs, 5);
    gtk_box_append(GTK_BOX(box), time_sig_row);

    // Auto-save interval spinner
    GtkWidget *autosave_row = create_labeled_spinner("Auto-save (min):", 0, 60, 1, 5);
    gtk_box_append(GTK_BOX(box), autosave_row);

    // Info label
    GtkWidget *info = gtk_label_new(NULL);
    gtk_label_set_markup(GTK_LABEL(info),
        "<span foreground='" TOKYONIGHT_COMMENT "' size='small'>Note: Auto-save interval of 0 disables auto-save.</span>");
    gtk_label_set_wrap(GTK_LABEL(info), TRUE);
    gtk_widget_set_halign(info, GTK_ALIGN_START);
    gtk_widget_set_margin_top(info, 16);
    gtk_box_append(GTK_BOX(box), info);

    gtk_scrolled_window_set_child(GTK_SCROLLED_WINDOW(scrolled), box);
    return scrolled;
}

// File/Folders panel (placeholder)
static GtkWidget* create_file_folders_panel(SettingsModal *modal) {
    (void)modal;
    return create_placeholder_panel("File/Folders");
}

// Plugins panel (placeholder)
static GtkWidget* create_plugins_panel(SettingsModal *modal) {
    (void)modal;
    return create_placeholder_panel("Plugins");
}

// Advanced panel implementation
static GtkWidget* create_advanced_panel(SettingsModal *modal) {
    (void)modal;

    GtkWidget *scrolled = gtk_scrolled_window_new();
    gtk_scrolled_window_set_policy(GTK_SCROLLED_WINDOW(scrolled),
                                   GTK_POLICY_NEVER, GTK_POLICY_AUTOMATIC);

    GtkWidget *box = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0);
    gtk_widget_set_margin_start(box, 24);
    gtk_widget_set_margin_end(box, 24);
    gtk_widget_set_margin_top(box, 24);
    gtk_widget_set_margin_bottom(box, 24);

    // Title
    GtkWidget *title = gtk_label_new(NULL);
    gtk_label_set_markup(GTK_LABEL(title), "<span size='large' weight='bold'>Advanced Settings</span>");
    gtk_widget_set_halign(title, GTK_ALIGN_START);
    gtk_widget_set_margin_bottom(title, 16);
    gtk_box_append(GTK_BOX(box), title);

    // Debug mode switch
    GtkWidget *debug_row = create_labeled_switch("Debug Mode:", FALSE);
    gtk_box_append(GTK_BOX(box), debug_row);

    // Log level dropdown
    const char *log_levels[] = {"Error", "Warn", "Info", "Debug", "Trace", NULL};
    GtkWidget *log_row = create_labeled_dropdown("Log Level:", log_levels, 5);
    gtk_box_append(GTK_BOX(box), log_row);

    // Performance overlay switch
    GtkWidget *overlay_row = create_labeled_switch("Performance Overlay:", FALSE);
    gtk_box_append(GTK_BOX(box), overlay_row);

    // Warning label
    GtkWidget *warning = gtk_label_new(NULL);
    gtk_label_set_markup(GTK_LABEL(warning),
        "<span foreground='" TOKYONIGHT_ORANGE "' size='small' weight='bold'>⚠ Warning:</span>\n"
        "<span foreground='" TOKYONIGHT_COMMENT "' size='small'>Debug mode and verbose logging may impact performance.</span>");
    gtk_label_set_wrap(GTK_LABEL(warning), TRUE);
    gtk_widget_set_halign(warning, GTK_ALIGN_START);
    gtk_widget_set_margin_top(warning, 16);
    gtk_box_append(GTK_BOX(box), warning);

    gtk_scrolled_window_set_child(GTK_SCROLLED_WINDOW(scrolled), box);
    return scrolled;
}

// Update restart warning visibility
static void update_restart_warning(SettingsModal *modal) {
    if (!modal || !modal->restart_warning) return;

    gboolean requires_restart = CATEGORY_REQUIRES_RESTART[modal->current_category];
    gtk_widget_set_visible(modal->restart_warning, requires_restart);
}

// Category button click handler
static void on_category_clicked(GtkButton *button, gpointer user_data) {
    SettingsModal *modal = (SettingsModal *)user_data;
    if (!modal) return;

    // Find which category was clicked
    for (int i = 0; i < CATEGORY_COUNT; i++) {
        if ((void *)button == (void *)modal->category_buttons[i]) {
            modal->current_category = (SettingsCategory)i;

            // Update stack to show corresponding panel
            char page_name[32];
            snprintf(page_name, sizeof(page_name), "category-%d", i);
            gtk_stack_set_visible_child_name(GTK_STACK(modal->stack), page_name);

            // Update restart warning
            update_restart_warning(modal);

            // Update button states (highlight selected)
            for (int j = 0; j < CATEGORY_COUNT; j++) {
                if (j == i) {
                    gtk_widget_add_css_class(modal->category_buttons[j], "suggested-action");
                } else {
                    gtk_widget_remove_css_class(modal->category_buttons[j], "suggested-action");
                }
            }

            printf("⚙ Settings category changed to: %s\n", CATEGORY_NAMES[i]);
            break;
        }
    }
}

// Apply button handler
static void on_apply_clicked(GtkButton *button, gpointer user_data) {
    (void)button;
    SettingsModal *modal = (SettingsModal *)user_data;
    if (!modal) return;

    // Save settings to disk
    if (settings_save() == 0) {
        printf("✅ Settings saved to disk\n");
    } else {
        printf("⚠️ Failed to save settings to disk\n");
    }

    // Call user callback if set
    if (modal->apply_callback) {
        modal->apply_callback(modal->apply_user_data);
    }

    modal->has_changes = FALSE;
    settings_modal_hide(modal);
}

// Cancel button handler
static void on_cancel_clicked(GtkButton *button, gpointer user_data) {
    (void)button;
    SettingsModal *modal = (SettingsModal *)user_data;
    if (!modal) return;

    printf("❌ Settings cancelled\n");

    // Call user callback if set
    if (modal->cancel_callback) {
        modal->cancel_callback(modal->cancel_user_data);
    }

    modal->has_changes = FALSE;
    settings_modal_hide(modal);
}

// Dialog response handler - properly closes the dialog
static void on_dialog_response(GtkDialog *dialog, int response_id, gpointer user_data) {
    (void)response_id;
    (void)user_data;
    gtk_window_destroy(GTK_WINDOW(dialog));
}

// Reset button handler
static void on_reset_clicked(GtkButton *button, gpointer user_data) {
    (void)button;
    SettingsModal *modal = (SettingsModal *)user_data;
    if (!modal) return;

    // Show confirmation dialog
    GtkWidget *dialog = gtk_message_dialog_new(
        GTK_WINDOW(modal->window),
        GTK_DIALOG_MODAL | GTK_DIALOG_DESTROY_WITH_PARENT,
        GTK_MESSAGE_QUESTION,
        GTK_BUTTONS_YES_NO,
        "Reset all settings to defaults?"
    );

    gtk_message_dialog_format_secondary_text(
        GTK_MESSAGE_DIALOG(dialog),
        "This will reset all settings to their default values. This action cannot be undone."
    );

    gtk_window_present(GTK_WINDOW(dialog));

    // Handle response - use proper callback that receives dialog as first arg
    g_signal_connect(dialog, "response", G_CALLBACK(on_dialog_response), modal);

    printf("🔄 Reset to defaults requested\n");

    // Call user callback if set
    if (modal->reset_callback) {
        modal->reset_callback(modal->reset_user_data);
    }
}

// Handle window close - hide instead of destroy
static gboolean on_window_close_request(GtkWindow *window, gpointer user_data) {
    (void)user_data;
    // Hide window instead of destroying
    gtk_widget_set_visible(GTK_WIDGET(window), FALSE);
    return TRUE;  // Prevent default destroy behavior
}

// Public API implementation

SettingsModal* settings_modal_new(GtkWindow *parent) {
    SettingsModal *modal = malloc(sizeof(SettingsModal));
    if (!modal) return NULL;

    modal->current_category = CATEGORY_SYSTEM;
    modal->has_changes = FALSE;
    modal->apply_callback = NULL;
    modal->apply_user_data = NULL;
    modal->cancel_callback = NULL;
    modal->cancel_user_data = NULL;
    modal->reset_callback = NULL;
    modal->reset_user_data = NULL;

    // Create window (not modal - modal blocks dropdowns on macOS)
    modal->window = gtk_window_new();
    gtk_window_set_title(GTK_WINDOW(modal->window), "Settings");
    gtk_window_set_default_size(GTK_WINDOW(modal->window), MODAL_WIDTH, MODAL_HEIGHT);
    gtk_window_set_resizable(GTK_WINDOW(modal->window), TRUE);
    // Note: Not using gtk_window_set_modal(TRUE) as it blocks dropdown popovers on macOS

    if (parent) {
        gtk_window_set_transient_for(GTK_WINDOW(modal->window), parent);
    }

    // Handle close button - hide instead of destroy
    g_signal_connect(modal->window, "close-request", G_CALLBACK(on_window_close_request), modal);

    // Main container
    GtkWidget *main_box = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0);

    // Content area (sidebar + stack)
    GtkWidget *content_box = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 0);
    gtk_widget_set_vexpand(content_box, TRUE);

    // Sidebar for categories
    modal->sidebar = gtk_box_new(GTK_ORIENTATION_VERTICAL, 4);
    gtk_widget_set_size_request(modal->sidebar, SIDEBAR_WIDTH, -1);
    gtk_widget_set_margin_start(modal->sidebar, 8);
    gtk_widget_set_margin_end(modal->sidebar, 8);
    gtk_widget_set_margin_top(modal->sidebar, 8);
    gtk_widget_set_margin_bottom(modal->sidebar, 8);

    // Add category buttons to sidebar
    for (int i = 0; i < CATEGORY_COUNT; i++) {
        GtkWidget *button = gtk_button_new_with_label(CATEGORY_NAMES[i]);
        gtk_widget_set_halign(button, GTK_ALIGN_FILL);
        modal->category_buttons[i] = button;
        g_signal_connect(button, "clicked", G_CALLBACK(on_category_clicked), modal);
        gtk_box_append(GTK_BOX(modal->sidebar), button);
    }

    // Highlight first category by default
    gtk_widget_add_css_class(modal->category_buttons[0], "suggested-action");

    gtk_box_append(GTK_BOX(content_box), modal->sidebar);

    // Separator between sidebar and content
    GtkWidget *separator = gtk_separator_new(GTK_ORIENTATION_VERTICAL);
    gtk_box_append(GTK_BOX(content_box), separator);

    // Stack for category panels
    modal->stack = gtk_stack_new();
    gtk_widget_set_hexpand(modal->stack, TRUE);
    gtk_widget_set_vexpand(modal->stack, TRUE);
    gtk_stack_set_transition_type(GTK_STACK(modal->stack), GTK_STACK_TRANSITION_TYPE_CROSSFADE);
    gtk_stack_set_transition_duration(GTK_STACK(modal->stack), 150);

    // Add all category panels to stack
    GtkWidget* (*panel_creators[CATEGORY_COUNT])(SettingsModal*) = {
        create_system_panel,
        create_audio_panel,
        create_display_panel,
        create_graphics_panel,
        create_midi_panel,
        create_performance_panel,
        create_appearance_panel,
        create_project_panel,
        create_file_folders_panel,
        create_plugins_panel,
        create_advanced_panel
    };

    for (int i = 0; i < CATEGORY_COUNT; i++) {
        char page_name[32];
        snprintf(page_name, sizeof(page_name), "category-%d", i);
        GtkWidget *panel = panel_creators[i](modal);
        gtk_stack_add_named(GTK_STACK(modal->stack), panel, page_name);
    }

    gtk_box_append(GTK_BOX(content_box), modal->stack);
    gtk_box_append(GTK_BOX(main_box), content_box);

    // Bottom button bar
    GtkWidget *button_bar = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8);
    gtk_widget_set_margin_start(button_bar, 12);
    gtk_widget_set_margin_end(button_bar, 12);
    gtk_widget_set_margin_top(button_bar, 8);
    gtk_widget_set_margin_bottom(button_bar, 12);

    // Restart warning label (left side)
    modal->restart_warning = gtk_label_new(NULL);
    gtk_label_set_markup(GTK_LABEL(modal->restart_warning),
        "<span foreground='" TOKYONIGHT_ORANGE "'>⚠ Changes require restart</span>");
    gtk_widget_set_halign(modal->restart_warning, GTK_ALIGN_START);
    gtk_widget_set_visible(modal->restart_warning, TRUE); // Audio is default
    gtk_box_append(GTK_BOX(button_bar), modal->restart_warning);

    // Spacer
    GtkWidget *spacer = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 0);
    gtk_widget_set_hexpand(spacer, TRUE);
    gtk_box_append(GTK_BOX(button_bar), spacer);

    // Reset button (left-aligned of action buttons)
    modal->reset_button = gtk_button_new_with_label("Reset Defaults");
    gtk_widget_add_css_class(modal->reset_button, "destructive-action");
    g_signal_connect(modal->reset_button, "clicked", G_CALLBACK(on_reset_clicked), modal);
    gtk_box_append(GTK_BOX(button_bar), modal->reset_button);

    // Cancel button
    modal->cancel_button = gtk_button_new_with_label("Cancel");
    g_signal_connect(modal->cancel_button, "clicked", G_CALLBACK(on_cancel_clicked), modal);
    gtk_box_append(GTK_BOX(button_bar), modal->cancel_button);

    // Apply button
    modal->apply_button = gtk_button_new_with_label("Apply");
    gtk_widget_add_css_class(modal->apply_button, "suggested-action");
    g_signal_connect(modal->apply_button, "clicked", G_CALLBACK(on_apply_clicked), modal);
    gtk_box_append(GTK_BOX(button_bar), modal->apply_button);

    gtk_box_append(GTK_BOX(main_box), button_bar);

    gtk_window_set_child(GTK_WINDOW(modal->window), main_box);

    printf("⚙ Settings modal created (900x600)\n");
    printf("   - 11 categories (System info + settings)\n");
    printf("   - Ableton-style layout\n");
    printf("   - Tokyo Night theme\n");

    return modal;
}

void settings_modal_show(SettingsModal *modal) {
    if (!modal || !modal->window) return;
    gtk_window_present(GTK_WINDOW(modal->window));
}

void settings_modal_hide(SettingsModal *modal) {
    if (!modal || !modal->window) return;
    gtk_widget_set_visible(modal->window, FALSE);
}

void settings_modal_destroy(SettingsModal *modal) {
    if (!modal) return;

    if (modal->window) {
        gtk_window_destroy(GTK_WINDOW(modal->window));
    }

    free(modal);
    printf("⚙ Settings modal destroyed\n");
}

void settings_modal_set_apply_callback(SettingsModal *modal, SettingsApplyCallback callback, void *user_data) {
    if (!modal) return;
    modal->apply_callback = callback;
    modal->apply_user_data = user_data;
}

void settings_modal_set_cancel_callback(SettingsModal *modal, SettingsCancelCallback callback, void *user_data) {
    if (!modal) return;
    modal->cancel_callback = callback;
    modal->cancel_user_data = user_data;
}

void settings_modal_set_reset_callback(SettingsModal *modal, SettingsResetCallback callback, void *user_data) {
    if (!modal) return;
    modal->reset_callback = callback;
    modal->reset_user_data = user_data;
}

// ============================================================================
// Stub implementations for Zig settings update functions
// These will be called from Zig when settings values change in the modal
// ============================================================================

void settings_modal_set_callbacks(
    SettingsModal *modal,
    void *user_data,
    void (*on_apply)(void*),
    void (*on_cancel)(void*)
) {
    if (!modal) return;
    // Store callbacks (these are placeholders for now)
    (void)user_data;
    (void)on_apply;
    (void)on_cancel;
}

// Audio settings updates (stubs for now)
void settings_modal_update_audio_backend(SettingsModal *modal, int backend) {
    (void)modal; (void)backend;
}

void settings_modal_update_sample_rate(SettingsModal *modal, unsigned int rate) {
    (void)modal; (void)rate;
}

void settings_modal_update_buffer_size(SettingsModal *modal, unsigned int size) {
    (void)modal; (void)size;
}

// Display settings updates
void settings_modal_update_display_backend(SettingsModal *modal, int backend) {
    (void)modal; (void)backend;
}

void settings_modal_update_fullscreen_mode(SettingsModal *modal, int mode) {
    (void)modal; (void)mode;
}

void settings_modal_update_window_scale(SettingsModal *modal, float scale) {
    (void)modal; (void)scale;
}

// Graphics settings updates
void settings_modal_update_graphics_renderer(SettingsModal *modal, int renderer) {
    (void)modal; (void)renderer;
}

void settings_modal_update_vsync(SettingsModal *modal, int enabled) {
    (void)modal; (void)enabled;
}

void settings_modal_update_max_fps(SettingsModal *modal, unsigned int fps) {
    (void)modal; (void)fps;
}

// Performance settings updates
void settings_modal_update_redraw_strategy(SettingsModal *modal, int strategy) {
    (void)modal; (void)strategy;
}

void settings_modal_update_enable_culling(SettingsModal *modal, int enabled) {
    (void)modal; (void)enabled;
}

void settings_modal_update_enable_batching(SettingsModal *modal, int enabled) {
    (void)modal; (void)enabled;
}

void settings_modal_update_audio_thread_count(SettingsModal *modal, unsigned char count) {
    (void)modal; (void)count;
}

// Appearance settings updates
void settings_modal_update_theme(SettingsModal *modal, int theme) {
    (void)modal; (void)theme;
}

void settings_modal_update_ui_scale(SettingsModal *modal, float scale) {
    (void)modal; (void)scale;
}

void settings_modal_update_font_size(SettingsModal *modal, unsigned char size) {
    (void)modal; (void)size;
}

// Project settings updates
void settings_modal_update_default_bpm(SettingsModal *modal, float bpm) {
    (void)modal; (void)bpm;
}

void settings_modal_update_default_time_sig(SettingsModal *modal, unsigned char num, unsigned char den) {
    (void)modal; (void)num; (void)den;
}

void settings_modal_update_auto_save_interval(SettingsModal *modal, unsigned int seconds) {
    (void)modal; (void)seconds;
}

// Advanced settings updates
void settings_modal_update_debug_mode(SettingsModal *modal, int enabled) {
    (void)modal; (void)enabled;
}

void settings_modal_update_log_level(SettingsModal *modal, int level) {
    (void)modal; (void)level;
}

void settings_modal_update_show_performance_overlay(SettingsModal *modal, int enabled) {
    (void)modal; (void)enabled;
}
