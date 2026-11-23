#ifndef SETTINGS_MODAL_GTK_H
#define SETTINGS_MODAL_GTK_H

#include <gtk/gtk.h>
#include <stdbool.h>
#include <stdint.h>

typedef struct SettingsModal SettingsModal;

// Callback types for settings actions
typedef void (*SettingsApplyCallback)(void *user_data);
typedef void (*SettingsCancelCallback)(void *user_data);
typedef void (*SettingsResetCallback)(void *user_data);

// System info struct (from Zig)
typedef struct {
    char os_name[32];
    char arch[16];
    char audio_backend[32];
    uint32_t sample_rate;
    uint32_t buffer_size;
    char midi_backend[32];
    uint32_t midi_inputs;
    uint32_t midi_outputs;
    uint32_t cpu_cores;
    uint32_t recommended_threads;
    bool has_gpu_acceleration;
    float display_scale;
} SystemInfo;

// System detection functions (from Zig)
extern SystemInfo system_get_info(void);
extern const char* system_get_os_name(void);
extern const char* system_get_audio_backend(void);
extern const char* system_get_midi_backend(void);
extern uint32_t system_get_cpu_cores(void);
extern uint32_t system_get_recommended_threads(void);
extern uint32_t system_get_midi_inputs(void);
extern uint32_t system_get_midi_outputs(void);
extern bool system_has_gpu_acceleration(void);
extern uint32_t system_get_default_sample_rate(void);
extern uint32_t system_get_default_buffer_size(void);

// Dynamic backend/rate/size lists (from Zig detection)
#define MAX_BACKENDS 8

typedef struct {
    char names[MAX_BACKENDS][32];
    uint32_t count;
} AudioBackendList;

typedef struct {
    uint32_t rates[8];
    uint32_t count;
} SampleRateList;

typedef struct {
    uint32_t sizes[8];
    uint32_t count;
} BufferSizeList;

extern AudioBackendList system_get_available_audio_backends(void);
extern uint32_t system_get_audio_backend_count(void);
extern const char* system_get_audio_backend_name(uint32_t index);
extern SampleRateList system_get_available_sample_rates(void);
extern BufferSizeList system_get_available_buffer_sizes(void);

// Graphics renderer detection (from Zig)
#define MAX_RENDERERS 4

typedef struct {
    char names[MAX_RENDERERS][32];
    uint32_t count;
} GraphicsRendererList;

extern GraphicsRendererList system_get_available_renderers(void);
extern const char* system_get_preferred_renderer(void);
extern const char* system_get_gpu_vendor(void);
extern const char* system_get_gpu_name(void);
extern uint32_t system_get_display_refresh_rate(void);

// Audio device enumeration (from Zig)
extern uint32_t system_get_input_device_count(void);
extern uint32_t system_get_output_device_count(void);
extern const char* system_get_input_device_name(uint32_t index);
extern const char* system_get_output_device_name(uint32_t index);

// Modal lifecycle
SettingsModal* settings_modal_new(GtkWindow *parent);
void settings_modal_show(SettingsModal *modal);
void settings_modal_hide(SettingsModal *modal);
void settings_modal_destroy(SettingsModal *modal);

// Set callbacks for button actions
void settings_modal_set_apply_callback(SettingsModal *modal, SettingsApplyCallback callback, void *user_data);
void settings_modal_set_cancel_callback(SettingsModal *modal, SettingsCancelCallback callback, void *user_data);
void settings_modal_set_reset_callback(SettingsModal *modal, SettingsResetCallback callback, void *user_data);

// =============================================================================
// Settings persistence C API (from Zig)
// =============================================================================

// Initialize/save settings
extern int settings_init(void);
extern int settings_save(void);
extern int settings_reload(void);

// Audio settings
extern int settings_get_audio_backend(void);
extern void settings_set_audio_backend(int backend);
extern unsigned int settings_get_sample_rate(void);
extern void settings_set_sample_rate(unsigned int rate);
extern unsigned int settings_get_buffer_size(void);
extern void settings_set_buffer_size(unsigned int size);

// Display settings
extern int settings_get_display_backend(void);
extern void settings_set_display_backend(int backend);
extern float settings_get_window_scale(void);
extern void settings_set_window_scale(float scale);
extern int settings_get_fullscreen_mode(void);
extern void settings_set_fullscreen_mode(int mode);

// Graphics settings
extern int settings_get_graphics_renderer(void);
extern void settings_set_graphics_renderer(int renderer);
extern int settings_get_vsync(void);
extern void settings_set_vsync(int enabled);
extern unsigned int settings_get_max_fps(void);
extern void settings_set_max_fps(unsigned int fps);

// Performance settings
extern int settings_get_redraw_strategy(void);
extern void settings_set_redraw_strategy(int strategy);
extern int settings_get_enable_culling(void);
extern void settings_set_enable_culling(int enabled);
extern int settings_get_enable_batching(void);
extern void settings_set_enable_batching(int enabled);
extern unsigned int settings_get_audio_thread_count(void);
extern void settings_set_audio_thread_count(unsigned int count);

// Appearance settings
extern int settings_get_theme(void);
extern void settings_set_theme(int theme);
extern float settings_get_ui_scale(void);
extern void settings_set_ui_scale(float scale);
extern unsigned int settings_get_font_size(void);
extern void settings_set_font_size(unsigned int size);

// Project settings
extern float settings_get_default_bpm(void);
extern void settings_set_default_bpm(float bpm);
extern unsigned int settings_get_default_time_sig_num(void);
extern void settings_set_default_time_sig_num(unsigned int num);
extern unsigned int settings_get_default_time_sig_den(void);
extern void settings_set_default_time_sig_den(unsigned int den);
extern unsigned int settings_get_auto_save_interval(void);
extern void settings_set_auto_save_interval(unsigned int seconds);

// Advanced settings
extern int settings_get_debug_mode(void);
extern void settings_set_debug_mode(int enabled);
extern int settings_get_log_level(void);
extern void settings_set_log_level(int level);
extern int settings_get_show_performance_overlay(void);
extern void settings_set_show_performance_overlay(int enabled);

#endif // SETTINGS_MODAL_GTK_H
