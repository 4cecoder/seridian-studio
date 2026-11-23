#include "main_window_gtk.h"
#include "components/settings_modal_gtk.h"
#include "components/instrument_modal_gtk.h"
#include "components/effects_chain_gtk.h"
#include "components/library_panel_gtk.h"
#include "components/timeline_viewport.h"
#include "components/piano_roll_gtk.h"
#include "components/daw_widgets.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>
#include <time.h>
#include <inttypes.h>

// Portable M_PI definition
#ifndef M_PI
#define M_PI 3.14159265358979323846
#endif

#ifndef M_PI
#define M_PI 3.14159265358979323846
#endif

// GTK4-specific defines
// GTK_WINDOW is already defined in GTK headers

// Tokyo Night Dark Theme CSS (embedded for portability)
static const char *tokyo_night_css =
"/* Tokyo Night Dark Theme for GTK4 DAW */\n"
"\n"
"/* Base window styling */\n"
"window {\n"
"    background-color: #1a1b26;\n"
"    color: #c0caf5;\n"
"}\n"
"\n"
"/* Box containers */\n"
"box {\n"
"    background-color: transparent;\n"
"}\n"
"\n"
"/* Labels */\n"
"label {\n"
"    color: #c0caf5;\n"
"}\n"
"\n"
"/* Buttons - default style */\n"
"button {\n"
"    background-color: #292e42;\n"
"    color: #c0caf5;\n"
"    border: 1px solid #565f89;\n"
"    border-radius: 4px;\n"
"    padding: 4px 12px;\n"
"    min-height: 24px;\n"
"}\n"
"\n"
"button:hover {\n"
"    background-color: alpha(#7aa2f7, 0.3);\n"
"    border-color: #7aa2f7;\n"
"}\n"
"\n"
"button:active {\n"
"    background-color: alpha(#7aa2f7, 0.5);\n"
"}\n"
"\n"
"button.destructive-action {\n"
"    background-color: alpha(#f7768e, 0.3);\n"
"    border-color: #f7768e;\n"
"    color: #f7768e;\n"
"}\n"
"\n"
"/* Frames */\n"
"frame {\n"
"    background-color: #16161e;\n"
"    border: 1px solid #292e42;\n"
"    border-radius: 4px;\n"
"}\n"
"\n"
"frame > label {\n"
"    color: #a9b1d6;\n"
"    font-weight: bold;\n"
"}\n"
"\n"
"/* Spin buttons */\n"
"spinbutton {\n"
"    background-color: #292e42;\n"
"    color: #c0caf5;\n"
"    border: 1px solid #565f89;\n"
"    border-radius: 4px;\n"
"}\n"
"\n"
"spinbutton:focus {\n"
"    border-color: #7aa2f7;\n"
"}\n"
"\n"
"spinbutton button {\n"
"    background-color: transparent;\n"
"    border: none;\n"
"}\n"
"\n"
"/* Sliders (faders) */\n"
"scale trough {\n"
"    background-color: #292e42;\n"
"    border-radius: 4px;\n"
"}\n"
"\n"
"scale highlight {\n"
"    background-color: #7aa2f7;\n"
"    border-radius: 4px;\n"
"}\n"
"\n"
"scale slider {\n"
"    background-color: #a9b1d6;\n"
"    border-radius: 50%;\n"
"}\n"
"\n"
"scale slider:hover {\n"
"    background-color: #c0caf5;\n"
"}\n"
"\n"
"/* Status bar */\n"
".statusbar {\n"
"    background-color: #16161e;\n"
"    border-top: 1px solid #292e42;\n"
"}\n"
"\n"
".statusbar label {\n"
"    color: #565f89;\n"
"}\n"
"\n"
"/* Entry fields */\n"
"entry {\n"
"    background-color: #292e42;\n"
"    color: #c0caf5;\n"
"    border: 1px solid #565f89;\n"
"    border-radius: 4px;\n"
"}\n"
"\n"
"entry:focus {\n"
"    border-color: #7aa2f7;\n"
"}\n"
"\n"
"/* Drop highlight for drag-and-drop */\n"
".drop-highlight {\n"
"    background-color: alpha(#7aa2f7, 0.3);\n"
"    border: 2px dashed #7aa2f7;\n"
"    border-radius: 4px;\n"
"}\n"
"\n"
"/* Search entry */\n"
"searchentry {\n"
"    background-color: #292e42;\n"
"    color: #c0caf5;\n"
"    border: 1px solid #565f89;\n"
"    border-radius: 4px;\n"
"}\n"
"\n"
"searchentry:focus {\n"
"    border-color: #7aa2f7;\n"
"}\n";

// Load and apply the Tokyo Night theme
void daw_load_theme(void) {
    GtkCssProvider *provider = gtk_css_provider_new();

    // Load the embedded CSS
    gtk_css_provider_load_from_string(provider, tokyo_night_css);

    // Apply to the default display
    GdkDisplay *display = gdk_display_get_default();
    if (display) {
        gtk_style_context_add_provider_for_display(
            display,
            GTK_STYLE_PROVIDER(provider),
            GTK_STYLE_PROVIDER_PRIORITY_APPLICATION
        );
        printf("🎨 Tokyo Night theme loaded\n");
    } else {
        fprintf(stderr, "Warning: Could not get default display for theming\n");
    }

    // Also set dark mode preference via settings
    GtkSettings *settings = gtk_settings_get_default();
    if (settings) {
        g_object_set(settings, "gtk-application-prefer-dark-theme", TRUE, NULL);
    }

    g_object_unref(provider);
}

// Tokyo Night color scheme - RGB values for Cairo (0.0-1.0 range)
typedef struct { double r, g, b; } Color;

static const Color COLOR_BG_DARK   = {0x16/255.0, 0x16/255.0, 0x1e/255.0};
static const Color COLOR_COMMENT   = {0x56/255.0, 0x5f/255.0, 0x89/255.0};
static const Color COLOR_FG        = {0xc0/255.0, 0xca/255.0, 0xf5/255.0};
static const Color COLOR_CYAN      = {0x7d/255.0, 0xcf/255.0, 0xff/255.0};
static const Color COLOR_GREEN     = {0x9e/255.0, 0xce/255.0, 0x6a/255.0};
static const Color COLOR_PURPLE    = {0xbb/255.0, 0x9a/255.0, 0xf7/255.0};
static const Color COLOR_RED       = {0xf7/255.0, 0x76/255.0, 0x8e/255.0};
static const Color COLOR_YELLOW    = {0xe0/255.0, 0xaf/255.0, 0x68/255.0};
static const Color COLOR_BLUE      = {0x7a/255.0, 0xa2/255.0, 0xf7/255.0};
static const Color COLOR_BG_HL     = {0x29/255.0, 0x2e/255.0, 0x42/255.0};

// Helper: Draw a horizontal meter bar with green/yellow/red zones
static void draw_meter_bar(cairo_t *cr, int x, int y, int width, int height, float level, double alpha) {
    int bar_width = (int)(level * width);
    if (bar_width <= 0) return;

    int green_end = (int)(width * 0.7);
    int yellow_end = (int)(width * 0.9);

    // Green zone (0-70%)
    int green_width = bar_width < green_end ? bar_width : green_end;
    cairo_set_source_rgba(cr, COLOR_GREEN.r, COLOR_GREEN.g, COLOR_GREEN.b, alpha);
    cairo_rectangle(cr, x, y, green_width, height);
    cairo_fill(cr);

    // Yellow zone (70-90%)
    if (bar_width > green_end) {
        int yellow_width = bar_width < yellow_end ? bar_width - green_end : yellow_end - green_end;
        cairo_set_source_rgba(cr, COLOR_YELLOW.r, COLOR_YELLOW.g, COLOR_YELLOW.b, alpha);
        cairo_rectangle(cr, x + green_end, y, yellow_width, height);
        cairo_fill(cr);
    }

    // Red zone (90-100%)
    if (bar_width > yellow_end) {
        int red_width = bar_width - yellow_end;
        cairo_set_source_rgba(cr, COLOR_RED.r, COLOR_RED.g, COLOR_RED.b, alpha);
        cairo_rectangle(cr, x + yellow_end, y, red_width, height);
        cairo_fill(cr);
    }
}

// Helper: Draw fader handle at position
static void draw_fader_handle(cairo_t *cr, int x, int height, const Color *color) {
    cairo_set_source_rgb(cr, color->r, color->g, color->b);
    cairo_set_line_width(cr, 3.0);
    cairo_move_to(cr, x, 0);
    cairo_line_to(cr, x, height);
    cairo_stroke(cr);
}

// Helper: Draw widget border
static void draw_border(cairo_t *cr, int width, int height) {
    cairo_set_source_rgb(cr, COLOR_COMMENT.r, COLOR_COMMENT.g, COLOR_COMMENT.b);
    cairo_set_line_width(cr, 1.0);
    cairo_rectangle(cr, 0, 0, width, height);
    cairo_stroke(cr);
}

// Helper: Fill background with dark color
static void fill_background(cairo_t *cr, int width, int height) {
    cairo_set_source_rgb(cr, COLOR_BG_DARK.r, COLOR_BG_DARK.g, COLOR_BG_DARK.b);
    cairo_rectangle(cr, 0, 0, width, height);
    cairo_fill(cr);
}

// Helper: Clamp gain value to valid range
static float clamp_gain(float gain) {
    if (gain < 0.0f) return 0.0f;
    if (gain > 1.0f) return 1.0f;
    return gain;
}

// Forward declarations for drawing functions
static void draw_timeline(GtkDrawingArea *area, cairo_t *cr, int width, int height, gpointer user_data);
static void draw_fader_meter(GtkDrawingArea *area, cairo_t *cr, int width, int height, gpointer user_data);
static void draw_master_fader_meter(GtkDrawingArea *area, cairo_t *cr, int width, int height, gpointer user_data);
static void draw_pan_knob(GtkDrawingArea *area, cairo_t *cr, int width, int height, gpointer user_data);

// Forward declarations for callbacks
static void on_bpm_changed(GtkSpinButton *spin, gpointer user_data);
static void on_time_sig_changed(GtkSpinButton *spin, gpointer user_data);
static void on_timeline_click(GtkGestureClick *gesture, int n_press, double x, double y, gpointer user_data);
static void on_window_state_changed(GtkWidget *widget, GParamSpec *pspec, gpointer user_data);
static void on_window_realize(GtkWidget *widget, gpointer user_data);
static void on_fader_drag(GtkGestureDrag *gesture, double x, double y, gpointer user_data);
static void update_status_display(MainWindow *win);
static void on_save_as_response(GtkNativeDialog *dialog, int response, gpointer user_data);

// Context menu and clip management
static void create_timeline_context_menu(MainWindow *win);
static void show_timeline_context_menu(MainWindow *win, double x, double y);
static void on_context_add_clip(GtkButton *button, gpointer user_data);
static void on_context_delete_clip(GtkButton *button, gpointer user_data);
static void on_context_split_clip(GtkButton *button, gpointer user_data);
static void on_context_duplicate_clip(GtkButton *button, gpointer user_data);

// Clip dragging
static void on_timeline_drag_begin(GtkGestureDrag *gesture, double x, double y, gpointer user_data);
static void on_timeline_drag_update(GtkGestureDrag *gesture, double offset_x, double offset_y, gpointer user_data);
static void on_timeline_drag_end(GtkGestureDrag *gesture, double offset_x, double offset_y, gpointer user_data);

// Motion handler for cursor changes
static void on_timeline_motion(GtkEventControllerMotion *controller, double x, double y, gpointer user_data);

// Number of tracks (easily configurable)
#define NUM_TRACKS 4

// Timeline layout constants
#define TRACK_HEADER_WIDTH 100
#define RULER_HEIGHT 28
#define MIN_TRACK_HEIGHT 60

struct MainWindow {
    // Core widgets
    GtkWidget *window;
    GtkWidget *main_box;
    GMainLoop *main_loop;
    void *audio_engine;

    // Transport controls
    GtkWidget *play_button;
    GtkWidget *stop_button;
    GtkWidget *record_button;
    GtkWidget *position_label;
    GtkWidget *transport_bar;
    GtkWidget *bpm_spin;
    GtkWidget *time_sig_num;
    GtkWidget *time_sig_den;

    // Timeline
    GtkWidget *timeline_area;

    // Mixer (Logic Pro-style combined fader+meter)
    GtkWidget *mixer_box;
    GtkWidget *track_fader_meters[NUM_TRACKS];
    GtkWidget *master_fader_meter;

    // Status
    GtkWidget *status_label;

    // Settings
    SettingsModal *settings_modal;

    // Instrument modals (one per track)
    InstrumentModal *instrument_modals[NUM_TRACKS];

    // Effects chain editors (one per track + master)
    EffectsChainEditor *effects_editors[NUM_TRACKS];
    EffectsChainEditor *master_effects_editor;

    // Library panel
    LibraryPanel *library_panel;

    // Track drop zones (for drag-and-drop)
    GtkWidget *track_drop_zones[NUM_TRACKS];

    // Timeline viewport (zoom/scroll state)
    TimelineViewport *viewport;

    // Track colors (for visual organization)
    uint32_t track_colors[NUM_TRACKS];

    // Clip selection state
    int selected_track;          // -1 = none
    uint64_t selected_clip_id;   // 0 = none

    // Context menu state
    GtkWidget *timeline_context_menu;
    double context_click_time;   // Time position of right-click
    int context_click_track;     // Track of right-click

    // Clip dragging state
    gboolean dragging_clip;
    gboolean dragging_midi_clip;  // TRUE if dragging a MIDI clip, FALSE for audio clip
    double drag_start_time;
    double drag_offset;

    // Clip trimming state
    gboolean is_trimming;
    int trim_mode;              // 0 = left edge, 1 = right edge
    double trim_start_time;     // Original clip start before drag
    double trim_start_duration; // Original duration before drag
    double trim_mouse_start_x;  // Mouse x when drag started

    // Playback state
    gboolean playing;
    gboolean recording;
    int recording_track;       // Track being recorded to
    gdouble recording_start;   // Start position of recording
    gdouble position;
    guint timer_id;
    double bpm;
    int time_sig_numerator;
    int time_sig_denominator;

    // Meter levels (with smoothing)
    float master_meter_left;
    float master_meter_right;
    float track_meters[NUM_TRACKS];

    // Fader gain values (0.0 to 1.0)
    float track_gains[NUM_TRACKS];
    float master_gain;

    // Pan values (-1.0 to 1.0)
    float track_pans[NUM_TRACKS];

    // Pan knob widgets
    GtkWidget *track_pan_knobs[NUM_TRACKS];

    // Piano roll editor (shared, switches between tracks)
    PianoRoll *piano_roll;
};

// Callbacks
static void on_play_clicked(GtkButton *button, gpointer user_data) {
    MainWindow *win = (MainWindow *)user_data;
    win->playing = !win->playing;

    if (win->playing) {
        daw_transport_button_set_icon(GTK_WIDGET(button), "⏸", DAW_COLOR_YELLOW);
        // Start audio engine
        if (win->audio_engine) {
            if (audio_engine_start(win->audio_engine) == 0) {
                printf("▶ Playback started\n");
            } else {
                printf("❌ Failed to start audio engine\n");
                win->playing = false;
                daw_transport_button_set_icon(GTK_WIDGET(button), "▶", DAW_COLOR_GREEN);
            }
        }
    } else {
        daw_transport_button_set_icon(GTK_WIDGET(button), "▶", DAW_COLOR_GREEN);
        printf("⏸ Playback paused\n");
        // Stop audio engine
        if (win->audio_engine) {
            audio_engine_stop(win->audio_engine);
        }
    }
}

static void on_stop_clicked(GtkButton *button, gpointer user_data) {
    MainWindow *win = (MainWindow *)user_data;
    (void)button;

    win->playing = FALSE;
    win->position = 0.0;

    daw_transport_button_set_icon(win->play_button, "▶", DAW_COLOR_GREEN);
    gtk_label_set_text(GTK_LABEL(win->position_label), "1:1 | 00:00.000");

    // Stop audio engine and reset position to beginning
    if (win->audio_engine) {
        audio_engine_stop(win->audio_engine);
        audio_engine_set_position(win->audio_engine, 0);  // Reset to beginning
    }

    printf("⏹ Playback stopped, position reset to 0\n");
}

static void on_record_clicked(GtkButton *button, gpointer user_data) {
    MainWindow *win = (MainWindow *)user_data;

    if (!win->recording) {
        // Find first armed track
        int armed_track = -1;
        for (int i = 0; i < NUM_TRACKS; i++) {
            if (audio_engine_get_track_arm(win->audio_engine, i)) {
                armed_track = i;
                break;
            }
        }

        if (armed_track < 0) {
            printf("⚠ No track armed for recording\n");
            main_window_set_status(win, "Arm a track first!");
            return;
        }

        // Initialize recording if needed
        static int recording_initialized = 0;
        if (!recording_initialized) {
            if (recording_init(48000) == 0) {
                recording_initialized = 1;
            } else {
                printf("❌ Failed to initialize recording\n");
                return;
            }
        }

        // Start recording
        if (recording_start(armed_track, win->position) == 0) {
            win->recording = TRUE;
            win->recording_track = armed_track;
            win->recording_start = win->position;
            daw_transport_button_set_icon(GTK_WIDGET(button), "⏹", DAW_COLOR_RED);
            printf("⏺ Recording to track %d at %.2fs\n", armed_track + 1, win->position);
            main_window_set_status(win, "Recording...");

            // Auto-start playback if not already playing
            if (!audio_engine_is_playing(win->audio_engine)) {
                audio_engine_start(win->audio_engine);
                win->playing = TRUE;
                daw_transport_button_set_icon(win->play_button, "⏸", DAW_COLOR_GREEN);
                printf("▶ Auto-started playback for recording\n");
            }
        } else {
            printf("❌ Failed to start recording\n");
        }
    } else {
        // Stop recording
        recording_stop();
        win->recording = FALSE;
        daw_transport_button_set_icon(GTK_WIDGET(button), "⏺", DAW_COLOR_RED);

        double duration = recording_get_duration();
        printf("⏹ Recording stopped: %.2fs\n", duration);

        // Save to project Audio folder and add as clip
        if (duration > 0.1) {  // Only save if there's meaningful content
            char path[512] = {0};
            char clip_name[64];
            long timestamp = (long)time(NULL);

            if (project_has_save_location()) {
                const char *folder = project_get_folder_path();
                if (folder) {
                    snprintf(path, sizeof(path), "%s/Audio/recording_%ld.wav", folder, timestamp);
                }
            } else {
                // Save to temp location
                snprintf(path, sizeof(path), "/tmp/daw_recording_%ld.wav", timestamp);
            }

            // First, load the audio into the track for immediate playback
            const float *audio_data = recording_get_data_ptr();
            uint64_t sample_count = recording_get_sample_count();
            uint32_t sample_rate = recording_get_sample_rate();

            printf("📊 Recording data: ptr=%p, samples=%" PRIu64 ", rate=%u\n",
                   (void*)audio_data, sample_count, sample_rate);

            if (audio_data && sample_count > 0) {
                int result = audio_engine_load_track_audio(win->audio_engine,
                    win->recording_track, audio_data, sample_count, 2, sample_rate);
                if (result == 0) {
                    printf("🎵 Loaded %" PRIu64 " samples into track %d for playback\n",
                           sample_count, win->recording_track + 1);
                } else {
                    printf("⚠️ Failed to load audio into track\n");
                }
            } else {
                printf("⚠️ No audio data to load (ptr=%p, count=%" PRIu64 ")\n",
                       (void*)audio_data, sample_count);
            }

            // Add clip to the track FIRST (even before saving, so it appears immediately)
            snprintf(clip_name, sizeof(clip_name), "Recording %ld", timestamp % 10000);
            // Use track color for recordings (default colors if not set)
            static const uint32_t default_track_colors[] = {0x7aa2f7, 0xbb9af7, 0x7dcfff, 0x9ece6a};
            uint32_t color = win->track_colors[win->recording_track];
            if (color == 0 && win->recording_track < 4) {
                color = default_track_colors[win->recording_track];
            }

            printf("📍 Adding clip: track=%d, start=%.2f, duration=%.2f, name=%s\n",
                   win->recording_track, win->recording_start, duration, clip_name);

            uint64_t clip_id = track_add_clip(win->audio_engine, win->recording_track,
                                               win->recording_start, duration,
                                               clip_name, color);

            if (clip_id > 0) {
                printf("🎤 Added recording clip to track %d (id=%" PRIu64 ", %.2fs at %.2fs)\n",
                       win->recording_track + 1, clip_id, duration, win->recording_start);
                main_window_set_status(win, "Recording added to track!");
                gtk_widget_queue_draw(win->timeline_area);

                // Record undo action for the recording
                char undo_desc[64];
                snprintf(undo_desc, sizeof(undo_desc), "Record on Track %d", win->recording_track + 1);
                undo_record_clip(UNDO_ADD_CLIP, win->recording_track, clip_id, undo_desc);
            } else {
                printf("❌ Failed to add clip to track (returned id=%" PRIu64 ")\n", clip_id);
            }

            // Also save to file for persistence
            if (path[0] && recording_save(path) == 0) {
                printf("💾 Recording saved: %s\n", path);
            } else if (path[0]) {
                printf("❌ Failed to save recording to: %s\n", path);
            }
        } else {
            main_window_set_status(win, "Recording too short");
        }
    }
}

static void on_mute_clicked(GtkButton *button, gpointer user_data) {
    MainWindow *win = (MainWindow *)user_data;

    // Get track index from button data
    int track = GPOINTER_TO_INT(g_object_get_data(G_OBJECT(button), "track-index"));

    // Get current mute state from engine
    int current_muted = audio_engine_get_track_mute(win->audio_engine, track);
    int new_muted = !current_muted;

    // Record undo action
    char desc[64];
    snprintf(desc, sizeof(desc), "%s Track %d", new_muted ? "Mute" : "Unmute", track + 1);
    undo_record_int(UNDO_SET_TRACK_MUTE, track, current_muted, new_muted, desc);

    // Toggle mute state
    audio_engine_set_track_mute(win->audio_engine, track, new_muted);

    // Update button appearance
    if (new_muted) {
        gtk_button_set_label(button, "M!");  // Muted indicator
    } else {
        gtk_button_set_label(button, "M");   // Normal
    }
}

static void on_solo_clicked(GtkButton *button, gpointer user_data) {
    MainWindow *win = (MainWindow *)user_data;

    // Get track index from button data
    int track = GPOINTER_TO_INT(g_object_get_data(G_OBJECT(button), "track-index"));

    // Get current solo state from engine
    int current_soloed = audio_engine_get_track_solo(win->audio_engine, track);
    int new_soloed = !current_soloed;

    // Record undo action
    char desc[64];
    snprintf(desc, sizeof(desc), "%s Track %d", new_soloed ? "Solo" : "Unsolo", track + 1);
    undo_record_int(UNDO_SET_TRACK_SOLO, track, current_soloed, new_soloed, desc);

    // Toggle solo state
    audio_engine_set_track_solo(win->audio_engine, track, new_soloed);

    // Update button appearance
    if (new_soloed) {
        gtk_button_set_label(button, "S!");  // Soloed indicator
    } else {
        gtk_button_set_label(button, "S");   // Normal
    }
}

static void on_settings_clicked(GtkButton *button, gpointer user_data) {
    (void)button;
    MainWindow *win = (MainWindow *)user_data;

    if (!win->settings_modal) {
        win->settings_modal = settings_modal_new(GTK_WINDOW(win->window));
    }

    if (win->settings_modal) {
        settings_modal_show(win->settings_modal);
        printf("⚙ Settings opened\n");
    }
}

// =============================================================================
// File Menu Callbacks
// =============================================================================

static void update_window_title(MainWindow *win) {
    char title[256];
    const char *name = project_get_name();
    int dirty = project_is_dirty();
    snprintf(title, sizeof(title), "%s%s - DAW v0.1.0",
             dirty ? "* " : "", name ? name : "Untitled");
    gtk_window_set_title(GTK_WINDOW(win->window), title);
}

// Sync engine state TO project (before save)
static void sync_engine_to_project(MainWindow *win) {
    // Sync BPM and time signature from UI
    project_set_bpm((float)gtk_spin_button_get_value(GTK_SPIN_BUTTON(win->bpm_spin)));
    project_set_time_sig(
        (int)gtk_spin_button_get_value(GTK_SPIN_BUTTON(win->time_sig_num)),
        (int)gtk_spin_button_get_value(GTK_SPIN_BUTTON(win->time_sig_den))
    );

    // Sync track states from engine
    for (int i = 0; i < NUM_TRACKS; i++) {
        project_set_track_volume(i, win->track_gains[i]);
        project_set_track_pan(i, win->track_pans[i]);
        project_set_track_muted(i, audio_engine_get_track_mute(win->audio_engine, i));
        project_set_track_solo(i, audio_engine_get_track_solo(win->audio_engine, i));
    }

    // Sync master volume
    project_set_master_volume(win->master_gain);
}

// Sync project state TO engine (after load)
static void sync_project_to_engine(MainWindow *win) {
    // Sync track states to engine and UI
    for (int i = 0; i < NUM_TRACKS; i++) {
        float vol = project_get_track_volume(i);
        float pan = project_get_track_pan(i);
        int muted = project_get_track_muted(i);
        int solo = project_get_track_solo(i);

        // Update engine
        audio_engine_set_track_gain(win->audio_engine, i, vol);
        audio_engine_set_track_pan(win->audio_engine, i, pan);
        audio_engine_set_track_mute(win->audio_engine, i, muted);
        audio_engine_set_track_solo(win->audio_engine, i, solo);

        // Update UI state
        win->track_gains[i] = vol;
        win->track_pans[i] = pan;
    }

    // Sync master volume
    float master = project_get_master_volume();
    audio_engine_set_master_gain(win->audio_engine, master);
    win->master_gain = master;

    // Redraw track controls
    for (int i = 0; i < NUM_TRACKS; i++) {
        gtk_widget_queue_draw(win->track_fader_meters[i]);
        gtk_widget_queue_draw(win->track_pan_knobs[i]);
    }
    gtk_widget_queue_draw(win->master_fader_meter);
}

static void on_new_project_clicked(GtkButton *button, gpointer user_data) {
    (void)button;
    MainWindow *win = (MainWindow *)user_data;

    // TODO: Check for unsaved changes first
    if (project_is_dirty()) {
        // For now, just warn
        printf("⚠ Warning: Unsaved changes will be lost\n");
    }

    project_new();

    // Reset UI state
    gtk_spin_button_set_value(GTK_SPIN_BUTTON(win->bpm_spin), 120.0);
    gtk_spin_button_set_value(GTK_SPIN_BUTTON(win->time_sig_num), 4.0);
    gtk_spin_button_set_value(GTK_SPIN_BUTTON(win->time_sig_den), 4.0);

    // Sync default project state to engine
    sync_project_to_engine(win);

    update_window_title(win);
    printf("📄 New project created\n");
}

static void on_open_response(GtkNativeDialog *dialog, int response, gpointer user_data) {
    MainWindow *win = (MainWindow *)user_data;

    if (response == GTK_RESPONSE_ACCEPT) {
        GtkFileChooser *chooser = GTK_FILE_CHOOSER(dialog);
        GFile *file = gtk_file_chooser_get_file(chooser);
        if (file) {
            char *path = g_file_get_path(file);
            if (path) {
                if (project_load(path) == 0) {
                    // Update UI from loaded project
                    gtk_spin_button_set_value(GTK_SPIN_BUTTON(win->bpm_spin), project_get_bpm());
                    gtk_spin_button_set_value(GTK_SPIN_BUTTON(win->time_sig_num), project_get_time_sig_num());
                    gtk_spin_button_set_value(GTK_SPIN_BUTTON(win->time_sig_den), project_get_time_sig_den());

                    // Sync loaded project state to engine
                    sync_project_to_engine(win);

                    update_window_title(win);
                    printf("📂 Project loaded: %s\n", path);
                } else {
                    printf("❌ Failed to load project: %s\n", path);
                }
                g_free(path);
            }
            g_object_unref(file);
        }
    }

    g_object_unref(dialog);
}

static void on_open_project_clicked(GtkButton *button, gpointer user_data) {
    (void)button;
    MainWindow *win = (MainWindow *)user_data;

    GtkFileChooserNative *dialog = gtk_file_chooser_native_new(
        "Open Project",
        GTK_WINDOW(win->window),
        GTK_FILE_CHOOSER_ACTION_SELECT_FOLDER,
        "_Open",
        "_Cancel"
    );

    g_signal_connect(dialog, "response", G_CALLBACK(on_open_response), win);
    gtk_native_dialog_show(GTK_NATIVE_DIALOG(dialog));
}

static void on_save_project_clicked(GtkButton *button, gpointer user_data) {
    (void)button;
    MainWindow *win = (MainWindow *)user_data;

    // Sync current engine state to project before saving
    sync_engine_to_project(win);

    if (project_has_save_location()) {
        // Save to existing location
        if (project_save(NULL) == 0) {
            update_window_title(win);
            printf("💾 Project saved\n");
        } else {
            printf("❌ Failed to save project\n");
        }
    } else {
        // No save location, trigger Save As
        on_save_as_response(NULL, GTK_RESPONSE_NONE, win);
    }
}

static void on_save_as_response(GtkNativeDialog *dialog, int response, gpointer user_data) {
    MainWindow *win = (MainWindow *)user_data;

    // If called from Save with no location, show dialog
    if (dialog == NULL) {
        GtkFileChooserNative *save_dialog = gtk_file_chooser_native_new(
            "Save Project As",
            GTK_WINDOW(win->window),
            GTK_FILE_CHOOSER_ACTION_SELECT_FOLDER,
            "_Save",
            "_Cancel"
        );

        g_signal_connect(save_dialog, "response", G_CALLBACK(on_save_as_response), win);
        gtk_native_dialog_show(GTK_NATIVE_DIALOG(save_dialog));
        return;
    }

    if (response == GTK_RESPONSE_ACCEPT) {
        GtkFileChooser *chooser = GTK_FILE_CHOOSER(dialog);
        GFile *file = gtk_file_chooser_get_file(chooser);
        if (file) {
            char *path = g_file_get_path(file);
            if (path) {
                if (project_save_as(path) == 0) {
                    update_window_title(win);
                    printf("💾 Project saved as: %s\n", path);
                } else {
                    printf("❌ Failed to save project: %s\n", path);
                }
                g_free(path);
            }
            g_object_unref(file);
        }
    }

    if (dialog) {
        g_object_unref(dialog);
    }
}

static void on_save_as_clicked(GtkButton *button, gpointer user_data) {
    (void)button;
    MainWindow *win = (MainWindow *)user_data;

    // Sync current engine state to project before saving
    sync_engine_to_project(win);

    GtkFileChooserNative *dialog = gtk_file_chooser_native_new(
        "Save Project As",
        GTK_WINDOW(win->window),
        GTK_FILE_CHOOSER_ACTION_SELECT_FOLDER,
        "_Save",
        "_Cancel"
    );

    g_signal_connect(dialog, "response", G_CALLBACK(on_save_as_response), win);
    gtk_native_dialog_show(GTK_NATIVE_DIALOG(dialog));
}

static void on_export_response(GtkNativeDialog *dialog, int response, gpointer user_data) {
    MainWindow *win = (MainWindow *)user_data;

    if (response == GTK_RESPONSE_ACCEPT) {
        GtkFileChooser *chooser = GTK_FILE_CHOOSER(dialog);
        GFile *file = gtk_file_chooser_get_file(chooser);
        if (file) {
            char *path = g_file_get_path(file);
            if (path) {
                // Auto-detect duration from clips (0 = auto, engine finds latest clip end)
                double duration = 0.0;

                printf("Exporting to: %s\n", path);

                // Export as 16-bit WAV
                if (audio_export_wav(win->audio_engine, path, duration, 16) == 0) {
                    printf("Export complete: %s\n", path);
                    main_window_set_status(win, "Export complete!");
                } else {
                    printf("Export failed: %s\n", path);
                    main_window_set_status(win, "Export failed!");
                }
                g_free(path);
            }
            g_object_unref(file);
        }
    }

    g_object_unref(dialog);
}

static void on_export_clicked(GtkButton *button, gpointer user_data) {
    (void)button;
    MainWindow *win = (MainWindow *)user_data;

    GtkFileChooserNative *dialog = gtk_file_chooser_native_new(
        "Export Audio",
        GTK_WINDOW(win->window),
        GTK_FILE_CHOOSER_ACTION_SAVE,
        "_Export",
        "_Cancel"
    );

    // Set default filename
    gtk_file_chooser_set_current_name(GTK_FILE_CHOOSER(dialog), "export.wav");

    g_signal_connect(dialog, "response", G_CALLBACK(on_export_response), win);
    gtk_native_dialog_show(GTK_NATIVE_DIALOG(dialog));
}

// =============================================================================
// Session Menu Wrappers (for daw_session_menu callbacks)
// =============================================================================

static void session_on_new(void *user_data) {
    on_new_project_clicked(NULL, user_data);
}

static void session_on_open(void *user_data) {
    on_open_project_clicked(NULL, user_data);
}

static void session_on_save(void *user_data) {
    on_save_project_clicked(NULL, user_data);
}

static void session_on_save_as(void *user_data) {
    on_save_as_clicked(NULL, user_data);
}

static void session_on_export_audio(void *user_data) {
    on_export_clicked(NULL, user_data);
}

static void session_on_export_midi(void *user_data) {
    MainWindow *win = (MainWindow *)user_data;
    main_window_set_status(win, "MIDI export coming soon!");
    printf("🎹 MIDI export not yet implemented\n");
}

static void session_on_import(void *user_data) {
    MainWindow *win = (MainWindow *)user_data;
    main_window_set_status(win, "Audio import coming soon!");
    printf("📥 Audio import not yet implemented\n");
}

// =============================================================================
// Undo/Redo Callbacks
// =============================================================================

// Global pointer for undo apply callback (set when window is created)
static MainWindow *g_main_window_for_undo = NULL;

// Apply callback for undo/redo - dispatches to appropriate engine functions
static void undo_apply_action(int action_type, int track, int is_undo,
                              int old_int, int new_int, float old_float, float new_float,
                              uint64_t clip_id) {
    MainWindow *win = g_main_window_for_undo;
    if (!win || !win->audio_engine) return;

    // Get the value to apply (old for undo, new for redo)
    int value_int = is_undo ? old_int : new_int;
    float value_float = is_undo ? old_float : new_float;

    switch (action_type) {
        case UNDO_SET_TRACK_MUTE:
            audio_engine_set_track_mute(win->audio_engine, track, value_int);
            break;

        case UNDO_SET_TRACK_SOLO:
            audio_engine_set_track_solo(win->audio_engine, track, value_int);
            break;

        case UNDO_SET_TRACK_VOLUME:
            audio_engine_set_track_gain(win->audio_engine, track, value_float);
            win->track_gains[track] = value_float;
            break;

        case UNDO_SET_TRACK_PAN:
            audio_engine_set_track_pan(win->audio_engine, track, value_float);
            break;

        case UNDO_SET_MASTER_VOLUME:
            audio_engine_set_master_gain(win->audio_engine, value_float);
            win->master_gain = value_float;
            break;

        case UNDO_SET_BPM:
            win->bpm = value_float;
            gtk_spin_button_set_value(GTK_SPIN_BUTTON(win->bpm_spin), value_float);
            break;

        case UNDO_SET_TIME_SIG: {
            int num = (value_int >> 16) & 0xFFFF;
            int den = value_int & 0xFFFF;
            win->time_sig_numerator = num;
            win->time_sig_denominator = den;
            gtk_spin_button_set_value(GTK_SPIN_BUTTON(win->time_sig_num), num);
            gtk_spin_button_set_value(GTK_SPIN_BUTTON(win->time_sig_den), den);
            break;
        }

        case UNDO_ADD_CLIP:
            // Undo add = remove the clip
            if (is_undo) {
                if (track_remove_clip(win->audio_engine, track, clip_id)) {
                    printf("↩ Undo: Removed clip %llu from track %d\n", (unsigned long long)clip_id, track + 1);
                    if (win->selected_clip_id == clip_id) {
                        win->selected_clip_id = 0;
                    }
                }
            }
            // Redo add = we'd need to re-add, but we don't store clip data
            // For now, redo of add_clip is not supported
            break;

        case UNDO_REMOVE_CLIP:
            // Undo remove = we'd need to re-add, but we don't store clip data
            // For now, undo of remove_clip is not supported
            // Redo remove = remove the clip
            if (!is_undo) {
                if (track_remove_clip(win->audio_engine, track, clip_id)) {
                    printf("↪ Redo: Removed clip %llu from track %d\n", (unsigned long long)clip_id, track + 1);
                }
            }
            break;

        default:
            printf("Undo: Unknown action type %d\n", action_type);
            break;
    }

    // Redraw timeline for clip changes
    if (action_type == UNDO_ADD_CLIP || action_type == UNDO_REMOVE_CLIP) {
        if (win->timeline_area) {
            gtk_widget_queue_draw(win->timeline_area);
        }
    }
}

static void on_undo_clicked(GtkButton *button, gpointer user_data) {
    (void)button;
    (void)user_data;

    if (undo_undo()) {
        printf("↩ Undo\n");
    }
}

static void on_redo_clicked(GtkButton *button, gpointer user_data) {
    (void)button;
    (void)user_data;

    if (undo_redo()) {
        printf("↪ Redo\n");
    }
}

// =============================================================================
// Track Controls
// =============================================================================

static void on_arm_clicked(GtkButton *button, gpointer user_data) {
    MainWindow *win = (MainWindow *)user_data;

    // Get track index from button data
    int track = GPOINTER_TO_INT(g_object_get_data(G_OBJECT(button), "track-index"));

    // Get current arm state from engine
    int current_armed = audio_engine_get_track_arm(win->audio_engine, track);

    // Toggle arm state
    audio_engine_set_track_arm(win->audio_engine, track, !current_armed);

    // Update button appearance
    if (!current_armed) {
        gtk_button_set_label(button, "R!");  // Armed indicator
        gtk_widget_add_css_class(GTK_WIDGET(button), "destructive-action");
    } else {
        gtk_button_set_label(button, "R");   // Normal
        gtk_widget_remove_css_class(GTK_WIDGET(button), "destructive-action");
    }
}

static void on_instrument_clicked(GtkButton *button, gpointer user_data) {
    MainWindow *win = (MainWindow *)user_data;

    // Get track index from button data
    int track = GPOINTER_TO_INT(g_object_get_data(G_OBJECT(button), "track-index"));

    // Create modal if not exists
    if (!win->instrument_modals[track]) {
        win->instrument_modals[track] = instrument_modal_new(
            GTK_WINDOW(win->window),
            win->audio_engine,
            track
        );
    }

    if (win->instrument_modals[track]) {
        instrument_modal_show(win->instrument_modals[track]);
        printf("🎹 Opened instrument modal for track %d\n", track + 1);
    }
}

static void on_effects_clicked(GtkButton *button, gpointer user_data) {
    MainWindow *win = (MainWindow *)user_data;

    // Get track index from button data
    int track = GPOINTER_TO_INT(g_object_get_data(G_OBJECT(button), "track-index"));

    // Create modal if not exists
    if (!win->effects_editors[track]) {
        win->effects_editors[track] = effects_chain_editor_new(
            GTK_WINDOW(win->window),
            win->audio_engine,
            track
        );
    }

    if (win->effects_editors[track]) {
        effects_chain_editor_show(win->effects_editors[track]);
        printf("🎛 Opened effects editor for track %d\n", track + 1);
    }
}

static void on_master_effects_clicked(GtkButton *button, gpointer user_data) {
    (void)button;
    MainWindow *win = (MainWindow *)user_data;

    // Create modal if not exists
    if (!win->master_effects_editor) {
        win->master_effects_editor = effects_chain_editor_new(
            GTK_WINDOW(win->window),
            win->audio_engine,
            -1  // -1 = master
        );
    }

    if (win->master_effects_editor) {
        effects_chain_editor_show(win->master_effects_editor);
        printf("🎛 Opened master effects editor\n");
    }
}

// Drop target handler for tracks
static gboolean on_track_drop(GtkDropTarget *target, const GValue *value, double x, double y, gpointer user_data) {
    (void)x;
    (void)y;

    MainWindow *win = (MainWindow *)user_data;
    if (!win) return FALSE;

    // Get track index from drop target
    int track = GPOINTER_TO_INT(g_object_get_data(G_OBJECT(target), "track-index"));

    // Get the dropped string value
    if (!G_VALUE_HOLDS_STRING(value)) {
        printf("❌ Drop: Invalid data type\n");
        return FALSE;
    }

    const char *data = g_value_get_string(value);
    if (!data) return FALSE;

    // Parse "type:index" format
    int type, index;
    if (sscanf(data, "%d:%d", &type, &index) != 2) {
        printf("❌ Drop: Invalid data format: %s\n", data);
        return FALSE;
    }

    printf("📥 Dropped item type=%d index=%d on track %d\n", type, index, track + 1);

    // Handle based on item type
    switch (type) {
        case 0:  // LIBRARY_ITEM_INSTRUMENT
            if (audio_engine_set_track_instrument(win->audio_engine, track, index) == 0) {
                const char *name = audio_engine_get_track_instrument_name(win->audio_engine, track);
                printf("🎹 Loaded instrument '%s' on track %d\n", name, track + 1);

                // Refresh instrument modal if open
                if (win->instrument_modals[track]) {
                    instrument_modal_refresh(win->instrument_modals[track]);
                }
            } else {
                printf("❌ Failed to load instrument on track %d\n", track + 1);
            }
            break;

        case 1:  // LIBRARY_ITEM_EFFECT
            printf("🎛 Effects not yet implemented\n");
            break;

        case 2:  // LIBRARY_ITEM_SAMPLE
            printf("🔊 Samples not yet implemented\n");
            break;

        case 3:  // LIBRARY_ITEM_PRESET
            printf("📁 Presets not yet implemented\n");
            break;

        default:
            printf("❓ Unknown item type: %d\n", type);
            return FALSE;
    }

    return TRUE;
}

// Drop target enter - highlight track
static GdkDragAction on_track_drop_enter(GtkDropTarget *target, double x, double y, gpointer user_data) {
    (void)x;
    (void)y;
    (void)user_data;

    GtkWidget *widget = gtk_event_controller_get_widget(GTK_EVENT_CONTROLLER(target));
    if (widget) {
        gtk_widget_add_css_class(widget, "drop-highlight");
    }

    return GDK_ACTION_COPY;
}

// Drop target leave - remove highlight
static void on_track_drop_leave(GtkDropTarget *target, gpointer user_data) {
    (void)user_data;

    GtkWidget *widget = gtk_event_controller_get_widget(GTK_EVENT_CONTROLLER(target));
    if (widget) {
        gtk_widget_remove_css_class(widget, "drop-highlight");
    }
}

// Note: Native GtkDropTarget handlers removed - macOS GdkMacosPasteboardItem crash
// Using custom GtkGestureDrag in library_panel_gtk.c instead

// Library item selected callback - loads to armed track
static void on_library_item_selected(int track, LibraryItemType type, int item_index, void *user_data) {
    MainWindow *win = (MainWindow *)user_data;
    if (!win) return;

    // Handle special track values
    int target_track = track;

    // -2 = custom drag to timeline, calculate track from current cursor position
    if (target_track == -2 && win->timeline_area) {
        // Get pointer position relative to timeline
        GdkSeat *seat = gdk_display_get_default_seat(gdk_display_get_default());
        if (seat) {
            GdkDevice *pointer = gdk_seat_get_pointer(seat);
            if (pointer) {
                // Get widget position
                graphene_point_t point = {0, 0};
                GtkWidget *root = GTK_WIDGET(gtk_widget_get_root(win->timeline_area));
                if (root && gtk_widget_compute_point(root, win->timeline_area, &point, &point)) {
                    // Get surface coordinates
                    GdkSurface *surface = gtk_native_get_surface(GTK_NATIVE(root));
                    if (surface) {
                        double root_x, root_y;
                        gdk_surface_get_device_position(surface, pointer, &root_x, &root_y, NULL);

                        // Calculate track from y position
                        int height = gtk_widget_get_height(win->timeline_area);
                        int content_height = height - RULER_HEIGHT;
                        int track_height = content_height / NUM_TRACKS;

                        // Get timeline position within window
                        graphene_rect_t bounds;
                        if (gtk_widget_compute_bounds(win->timeline_area, root, &bounds)) {
                            double timeline_y = root_y - bounds.origin.y;
                            target_track = (int)((timeline_y - RULER_HEIGHT) / track_height);
                            printf("📍 Cursor at y=%.0f, timeline_y=%.0f, track=%d\n",
                                   root_y, timeline_y, target_track);
                        }
                    }
                }
            }
        }

        // Clamp to valid range
        if (target_track < 0) target_track = 0;
        if (target_track >= NUM_TRACKS) target_track = NUM_TRACKS - 1;
    }

    // -1 = find armed track or use track 0
    if (target_track < 0) {
        target_track = 0;
        for (int i = 0; i < NUM_TRACKS; i++) {
            if (audio_engine_get_track_arm(win->audio_engine, i)) {
                target_track = i;
                break;
            }
        }
    }

    printf("📚 Loading item type=%d index=%d to track %d\n", type, item_index, target_track + 1);

    // Handle based on item type
    switch (type) {
        case 0:  // LIBRARY_ITEM_INSTRUMENT
            if (audio_engine_set_track_instrument(win->audio_engine, target_track, item_index) == 0) {
                const char *name = audio_engine_get_track_instrument_name(win->audio_engine, target_track);
                printf("🎹 Loaded instrument '%s' on track %d\n", name, target_track + 1);

                // Redraw timeline to show updated track name
                if (win->timeline_area) {
                    gtk_widget_queue_draw(win->timeline_area);
                }

                // Create instrument modal if not exists, then show it
                if (!win->instrument_modals[target_track]) {
                    win->instrument_modals[target_track] = instrument_modal_new(
                        GTK_WINDOW(win->window),
                        win->audio_engine,
                        target_track
                    );
                } else {
                    instrument_modal_refresh(win->instrument_modals[target_track]);
                }

                // Auto-open the instrument modal
                if (win->instrument_modals[target_track]) {
                    instrument_modal_show(win->instrument_modals[target_track]);
                }
            } else {
                printf("❌ Failed to load instrument on track %d\n", target_track + 1);
            }
            break;

        case 1:  // LIBRARY_ITEM_EFFECT
            printf("🎛 Effects not yet implemented\n");
            break;

        case 2:  // LIBRARY_ITEM_SAMPLE
            printf("🔊 Samples not yet implemented\n");
            break;

        case 3:  // LIBRARY_ITEM_PRESET
            printf("📁 Presets not yet implemented\n");
            break;

        default:
            printf("❓ Unknown item type: %d\n", type);
            break;
    }
}

// Helper: Smooth meter value (fast attack, slow decay)
static float smooth_meter(float current, float new_value) {
    return (new_value > current) ? new_value : current * 0.85f;
}

// Timer callback for playback updates
static gboolean update_playback(gpointer user_data) {
    MainWindow *win = (MainWindow *)user_data;
    if (!win || !win->window || !win->position_label) {
        return G_SOURCE_REMOVE;
    }

    if (!win->playing) {
        return G_SOURCE_CONTINUE;
    }

    // Get actual position from audio engine (samples -> seconds)
    if (win->audio_engine) {
        uint64_t sample_pos = audio_engine_get_position(win->audio_engine);
        // Convert samples to seconds (assuming 48000 Hz sample rate)
        win->position = (double)sample_pos / 48000.0;
    } else {
        win->position += 0.1; // Fallback: Advance 100ms
    }

    // Calculate and display musical position (bar:beat | mm:ss.ms)
    double bpm = win->bpm > 0 ? win->bpm : 120.0;
    double sec_per_beat = 60.0 / bpm;
    double total_beats = win->position / sec_per_beat;
    int bar = (int)(total_beats / win->time_sig_numerator) + 1;
    int beat = ((int)total_beats % win->time_sig_numerator) + 1;
    int minutes = (int)(win->position / 60.0);
    double seconds = win->position - (minutes * 60.0);

    char pos_text[48];
    snprintf(pos_text, sizeof(pos_text), "%d:%d | %02d:%06.3f", bar, beat, minutes, seconds);
    gtk_label_set_text(GTK_LABEL(win->position_label), pos_text);

    // Update meters from audio engine with smoothing
    if (win->audio_engine) {
        win->master_meter_left = smooth_meter(win->master_meter_left,
            audio_engine_get_master_meter_left(win->audio_engine));
        win->master_meter_right = smooth_meter(win->master_meter_right,
            audio_engine_get_master_meter_right(win->audio_engine));

        for (int i = 0; i < NUM_TRACKS; i++) {
            win->track_meters[i] = smooth_meter(win->track_meters[i],
                audio_engine_get_track_meter(win->audio_engine, i));
        }
    }

    // Queue redraws for all meters
    for (int i = 0; i < NUM_TRACKS; i++) {
        if (win->track_fader_meters[i] && gtk_widget_get_realized(win->track_fader_meters[i])) {
            gtk_widget_queue_draw(win->track_fader_meters[i]);
        }
    }
    if (win->master_fader_meter && gtk_widget_get_realized(win->master_fader_meter)) {
        gtk_widget_queue_draw(win->master_fader_meter);
    }
    if (win->timeline_area && gtk_widget_get_realized(win->timeline_area)) {
        gtk_widget_queue_draw(win->timeline_area);
    }

    return G_SOURCE_CONTINUE;
}

// Helper: Update status bar with BPM and time signature
static void update_status_display(MainWindow *win) {
    char status[64];
    snprintf(status, sizeof(status), "♩ %.0f BPM | %d/%d",
             win->bpm, win->time_sig_numerator, win->time_sig_denominator);
    gtk_label_set_text(GTK_LABEL(win->status_label), status);

    if (win->timeline_area && gtk_widget_get_realized(win->timeline_area)) {
        gtk_widget_queue_draw(win->timeline_area);
    }
}

static void on_bpm_changed(GtkSpinButton *spin, gpointer user_data) {
    MainWindow *win = (MainWindow *)user_data;
    float old_bpm = win->bpm;
    float new_bpm = (float)gtk_spin_button_get_value(spin);

    if (old_bpm != new_bpm) {
        // Record undo action
        char desc[64];
        snprintf(desc, sizeof(desc), "Set BPM to %.0f", new_bpm);
        undo_record_float(UNDO_SET_BPM, -1, old_bpm, new_bpm, desc);
    }

    win->bpm = new_bpm;

    // Sync tempo to audio engine for MIDI playback
    if (win->audio_engine) {
        audio_engine_set_tempo(win->audio_engine, new_bpm);
    }

    update_status_display(win);
}

static void on_time_sig_changed(GtkSpinButton *spin, gpointer user_data) {
    MainWindow *win = (MainWindow *)user_data;
    (void)spin;
    int old_num = win->time_sig_numerator;
    int old_den = win->time_sig_denominator;
    int new_num = (int)gtk_spin_button_get_value(GTK_SPIN_BUTTON(win->time_sig_num));
    int new_den = (int)gtk_spin_button_get_value(GTK_SPIN_BUTTON(win->time_sig_den));

    if (old_num != new_num || old_den != new_den) {
        // Record undo action (pack num/den into single int)
        char desc[64];
        snprintf(desc, sizeof(desc), "Set time signature to %d/%d", new_num, new_den);
        int old_packed = (old_num << 16) | old_den;
        int new_packed = (new_num << 16) | new_den;
        undo_record_int(UNDO_SET_TIME_SIG, -1, old_packed, new_packed, desc);
    }

    win->time_sig_numerator = new_num;
    win->time_sig_denominator = new_den;
    update_status_display(win);
}

// Get which zone of a clip the mouse is over
// Returns: 0 = not on clip, 1 = left trim handle, 2 = right trim handle, 3 = clip body
static int get_clip_hit_zone(MainWindow *win, int track_idx, uint64_t clip_id, double x) {
    if (!win || !win->viewport || !win->audio_engine || clip_id == 0) return 0;

    double clip_start = track_get_clip_start(win->audio_engine, track_idx, clip_id);
    double clip_duration = track_get_clip_duration(win->audio_engine, track_idx, clip_id);

    double x1 = timeline_viewport_seconds_to_x(win->viewport, clip_start, TRACK_HEADER_WIDTH);
    double x2 = timeline_viewport_seconds_to_x(win->viewport, clip_start + clip_duration, TRACK_HEADER_WIDTH);

    const double TRIM_HANDLE_WIDTH = 10.0;  // 10 pixels for trim handles

    if (x >= x1 && x < x1 + TRIM_HANDLE_WIDTH) return 1;  // Left trim
    if (x > x2 - TRIM_HANDLE_WIDTH && x <= x2) return 2;  // Right trim
    if (x >= x1 && x <= x2) return 3;                     // Body (drag to move)
    return 0;
}

static void on_timeline_click(GtkGestureClick *gesture, int n_press, double x, double y, gpointer user_data) {
    MainWindow *win = (MainWindow *)user_data;
    if (!win || !win->viewport) return;

    // Get which button was clicked
    guint button = gtk_gesture_single_get_current_button(GTK_GESTURE_SINGLE(gesture));

    // Calculate track from y position
    int content_height = gtk_widget_get_height(win->timeline_area) - RULER_HEIGHT;
    int track_height = content_height / NUM_TRACKS;
    int clicked_track = (int)((y - RULER_HEIGHT) / track_height);
    if (clicked_track < 0) clicked_track = 0;
    if (clicked_track >= NUM_TRACKS) clicked_track = NUM_TRACKS - 1;

    // Right-click (button 3) = show context menu
    if (button == 3) {
        win->selected_track = clicked_track;
        win->context_click_track = clicked_track;
        win->context_click_time = timeline_viewport_x_to_seconds(win->viewport, x, TRACK_HEADER_WIDTH);
        if (win->context_click_time < 0) win->context_click_time = 0;

        // Check if clicking on a clip
        win->selected_clip_id = 0;
        int clip_count = track_get_clip_count(win->audio_engine, clicked_track);
        for (int i = 0; i < clip_count; i++) {
            uint64_t clip_id = track_get_clip_id(win->audio_engine, clicked_track, i);
            double start = track_get_clip_start(win->audio_engine, clicked_track, clip_id);
            double duration = track_get_clip_duration(win->audio_engine, clicked_track, clip_id);
            if (win->context_click_time >= start && win->context_click_time < start + duration) {
                win->selected_clip_id = clip_id;
                break;
            }
        }

        show_timeline_context_menu(win, x, y);
        gtk_widget_queue_draw(win->timeline_area);
        return;
    }

    // Check if click is in track header area (select track only)
    if (x < TRACK_HEADER_WIDTH) {
        win->selected_track = clicked_track;
        win->selected_clip_id = 0;
        printf("🎯 Selected track %d\n", clicked_track + 1);
        gtk_widget_queue_draw(win->timeline_area);
        return;
    }

    // Left-click in timeline content area
    double clicked_position = timeline_viewport_x_to_seconds(win->viewport, x, TRACK_HEADER_WIDTH);
    if (clicked_position < 0) clicked_position = 0;

    // Check if clicking on a clip (select it)
    uint64_t clicked_clip = 0;
    int clip_count = track_get_clip_count(win->audio_engine, clicked_track);
    for (int i = 0; i < clip_count; i++) {
        uint64_t clip_id = track_get_clip_id(win->audio_engine, clicked_track, i);
        double start = track_get_clip_start(win->audio_engine, clicked_track, clip_id);
        double duration = track_get_clip_duration(win->audio_engine, clicked_track, clip_id);
        if (clicked_position >= start && clicked_position < start + duration) {
            clicked_clip = clip_id;
            break;
        }
    }

    if (clicked_clip > 0) {
        // Check if clicking on trim handles of already-selected clip
        if (clicked_clip == win->selected_clip_id && clicked_track == win->selected_track) {
            int zone = get_clip_hit_zone(win, clicked_track, clicked_clip, x);
            if (zone == 1 || zone == 2) {
                // Start trimming
                win->is_trimming = TRUE;
                win->trim_mode = (zone == 1) ? 0 : 1;  // 0 = left, 1 = right
                win->trim_start_time = track_get_clip_start(win->audio_engine, clicked_track, clicked_clip);
                win->trim_start_duration = track_get_clip_duration(win->audio_engine, clicked_track, clicked_clip);
                win->trim_mouse_start_x = x;
                printf("✂️ Starting %s trim on clip %llu\n",
                       (zone == 1) ? "left" : "right", (unsigned long long)clicked_clip);
                return;
            }
        }

        // Select this audio clip
        win->selected_track = clicked_track;
        win->selected_clip_id = clicked_clip;
        printf("🎵 Selected clip %llu on track %d\n", (unsigned long long)clicked_clip, clicked_track + 1);

        // Double-click opens piano roll for MIDI editing
        if (n_press >= 2) {
            // Check if this track has an instrument (MIDI track)
            const char *inst_name = (const char *)audio_engine_get_track_instrument_name(win->audio_engine, clicked_track);
            if (inst_name != NULL && win->piano_roll) {
                // Open piano roll for this track
                piano_roll_set_track(win->piano_roll, clicked_track);
                piano_roll_show(win->piano_roll);
                printf("🎹 Opened piano roll for track %d (double-click)\n", clicked_track + 1);
            } else if (inst_name == NULL) {
                printf("📝 Double-click on audio clip - audio editor not yet implemented\n");
            }
        }
        gtk_widget_queue_draw(win->timeline_area);
        return;
    }

    // Check if clicking on a MIDI clip (instrument track with no audio clips)
    if (audio_engine_track_has_instrument(win->audio_engine, clicked_track)) {
        const ViewportState *vp = timeline_viewport_get_state(win->viewport);
        if (vp) {
            double clip_start_beat = midi_clip_get_start_beat(clicked_track);
            double clip_duration_beats = midi_clip_get_clip_duration(clicked_track);
            double midi_clip_start = clip_start_beat * vp->seconds_per_beat;
            double midi_clip_end = midi_clip_start + (clip_duration_beats * vp->seconds_per_beat);

            if (clicked_position >= midi_clip_start && clicked_position < midi_clip_end) {
                // Select this MIDI clip (use clip_id = 0 to indicate MIDI clip)
                win->selected_track = clicked_track;
                win->selected_clip_id = 0;  // MIDI clips use 0 to distinguish from audio clips
                printf("🎹 Selected MIDI clip on track %d\n", clicked_track + 1);

                // Double-click opens piano roll
                if (n_press >= 2 && win->piano_roll) {
                    piano_roll_set_track(win->piano_roll, clicked_track);
                    piano_roll_show(win->piano_roll);
                    printf("🎹 Opened piano roll for track %d (double-click on MIDI clip)\n", clicked_track + 1);
                }
                gtk_widget_queue_draw(win->timeline_area);
                return;
            }
        }
    }

    // No clip clicked - seek to position and clear clip selection
    win->selected_track = clicked_track;
    win->selected_clip_id = 0;
    win->position = clicked_position;

    // Double-click on instrument track (no clip) - open piano roll anyway
    if (n_press >= 2) {
        const char *inst_name = (const char *)audio_engine_get_track_instrument_name(win->audio_engine, clicked_track);
        printf("🔍 Double-click on track %d, instrument: %s\n", clicked_track + 1, inst_name ? inst_name : "NONE");
        if (inst_name != NULL && inst_name[0] != '\0' && win->piano_roll) {
            piano_roll_set_track(win->piano_roll, clicked_track);
            piano_roll_show(win->piano_roll);
            printf("🎹 Opened piano roll for track %d (double-click on track)\n", clicked_track + 1);
            gtk_widget_queue_draw(win->timeline_area);
            return;
        }
    }

    // Update display
    const ViewportState *vp = timeline_viewport_get_state(win->viewport);
    double total_beats = win->position / vp->seconds_per_beat;
    int current_bar = (int)(total_beats / win->time_sig_numerator) + 1;
    int current_beat = ((int)total_beats % win->time_sig_numerator) + 1;
    int minutes = (int)(win->position / 60.0);
    double seconds = win->position - (minutes * 60.0);
    char pos_text[48];
    snprintf(pos_text, sizeof(pos_text), "%d:%d | %02d:%06.3f",
             current_bar, current_beat, minutes, seconds);
    gtk_label_set_text(GTK_LABEL(win->position_label), pos_text);

    printf("⏭ Seeking to: Bar %d, Beat %d (%02d:%06.3f)\n",
           current_bar, current_beat, minutes, seconds);

    // Redraw timeline
    gtk_widget_queue_draw(win->timeline_area);
}

// Timeline scroll handler (horizontal scroll for panning)
static gboolean on_timeline_scroll(GtkEventControllerScroll *controller,
                                   double dx, double dy, gpointer user_data) {
    (void)controller;
    MainWindow *win = (MainWindow *)user_data;
    if (!win || !win->viewport) return FALSE;

    GdkModifierType state = gtk_event_controller_get_current_event_state(GTK_EVENT_CONTROLLER(controller));

    if (state & GDK_CONTROL_MASK) {
        // Ctrl+scroll = zoom
        double factor = (dy > 0) ? 0.9 : 1.1;  // Scroll up = zoom in

        // Get mouse position for zoom centering
        double mouse_x = 0, mouse_y = 0;
        GtkWidget *widget = gtk_event_controller_get_widget(GTK_EVENT_CONTROLLER(controller));
        // For now, zoom at center of timeline
        int width = gtk_widget_get_width(widget);
        mouse_x = TRACK_HEADER_WIDTH + (width - TRACK_HEADER_WIDTH) / 2;
        (void)mouse_y;

        timeline_viewport_zoom_at_point(win->viewport, mouse_x, factor, TRACK_HEADER_WIDTH);
        gtk_widget_queue_draw(win->timeline_area);
        return TRUE;
    } else if (state & GDK_SHIFT_MASK) {
        // Shift+scroll = horizontal scroll (if vertical scroll detected)
        const ViewportState *vp = timeline_viewport_get_state(win->viewport);
        double scroll_amount = dy * vp->seconds_per_beat * 0.5;
        timeline_viewport_scroll_by(win->viewport, scroll_amount);
        gtk_widget_queue_draw(win->timeline_area);
        return TRUE;
    } else {
        // Regular horizontal scroll
        if (fabs(dx) > 0.01) {
            const ViewportState *vp = timeline_viewport_get_state(win->viewport);
            double scroll_amount = dx * vp->seconds_per_beat * 0.5;
            timeline_viewport_scroll_by(win->viewport, scroll_amount);
            gtk_widget_queue_draw(win->timeline_area);
            return TRUE;
        }
    }

    return FALSE;
}

// Keyboard handler for timeline (zoom shortcuts)
static gboolean on_timeline_key(GtkEventControllerKey *controller,
                                guint keyval, guint keycode,
                                GdkModifierType state, gpointer user_data) {
    (void)controller;
    (void)keycode;
    MainWindow *win = (MainWindow *)user_data;
    if (!win || !win->viewport) return FALSE;

    // Undo/Redo shortcuts (Cmd+Z / Cmd+Shift+Z on macOS, Ctrl+Z / Ctrl+Shift+Z on Linux)
    gboolean cmd_or_ctrl = (state & GDK_META_MASK) || (state & GDK_CONTROL_MASK);
    if (cmd_or_ctrl && (keyval == GDK_KEY_z || keyval == GDK_KEY_Z)) {
        if (state & GDK_SHIFT_MASK) {
            // Redo
            if (undo_redo()) {
                printf("↪ Redo: %s\n", undo_get_redo_desc() ? undo_get_redo_desc() : "(empty)");
            }
        } else {
            // Undo
            if (undo_undo()) {
                printf("↩ Undo: %s\n", undo_get_undo_desc() ? undo_get_undo_desc() : "(empty)");
            }
        }
        return TRUE;
    }

    // Zoom shortcuts
    if (keyval == GDK_KEY_plus || keyval == GDK_KEY_equal) {
        timeline_viewport_zoom_by(win->viewport, 1.2);
        gtk_widget_queue_draw(win->timeline_area);
        return TRUE;
    }
    if (keyval == GDK_KEY_minus) {
        timeline_viewport_zoom_by(win->viewport, 0.8);
        gtk_widget_queue_draw(win->timeline_area);
        return TRUE;
    }
    if (keyval == GDK_KEY_0 && (state & GDK_CONTROL_MASK)) {
        // Ctrl+0 = reset zoom
        timeline_viewport_set_zoom(win->viewport, 50.0);
        timeline_viewport_set_scroll(win->viewport, 0.0);
        gtk_widget_queue_draw(win->timeline_area);
        return TRUE;
    }

    // Arrow key scrolling
    if (keyval == GDK_KEY_Left) {
        const ViewportState *vp = timeline_viewport_get_state(win->viewport);
        timeline_viewport_scroll_by(win->viewport, -vp->seconds_per_beat);
        gtk_widget_queue_draw(win->timeline_area);
        return TRUE;
    }
    if (keyval == GDK_KEY_Right) {
        const ViewportState *vp = timeline_viewport_get_state(win->viewport);
        timeline_viewport_scroll_by(win->viewport, vp->seconds_per_beat);
        gtk_widget_queue_draw(win->timeline_area);
        return TRUE;
    }

    // Home = go to start
    if (keyval == GDK_KEY_Home) {
        timeline_viewport_set_scroll(win->viewport, 0.0);
        win->position = 0.0;
        gtk_widget_queue_draw(win->timeline_area);
        return TRUE;
    }

    // Space = Play/Pause toggle
    if (keyval == GDK_KEY_space) {
        if (audio_engine_is_playing(win->audio_engine)) {
            audio_engine_stop(win->audio_engine);
            printf("⏸ Paused (Space)\n");
        } else {
            audio_engine_start(win->audio_engine);
            printf("▶ Playing (Space)\n");
        }
        // Update play button visual state
        if (win->play_button) {
            GtkWidget *label = gtk_button_get_child(GTK_BUTTON(win->play_button));
            if (label && GTK_IS_LABEL(label)) {
                if (audio_engine_is_playing(win->audio_engine)) {
                    gtk_label_set_markup(GTK_LABEL(label),
                        "<span font_size='x-large' foreground='" DAW_COLOR_CYAN "'>⏸</span>");
                } else {
                    gtk_label_set_markup(GTK_LABEL(label),
                        "<span font_size='x-large' foreground='" DAW_COLOR_GREEN "'>▶</span>");
                }
            }
        }
        return TRUE;
    }

    // Return/Enter = Stop and rewind to start
    if (keyval == GDK_KEY_Return || keyval == GDK_KEY_KP_Enter) {
        audio_engine_stop(win->audio_engine);
        win->position = 0.0;
        timeline_viewport_set_scroll(win->viewport, 0.0);
        gtk_widget_queue_draw(win->timeline_area);
        // Update play button visual
        if (win->play_button) {
            GtkWidget *label = gtk_button_get_child(GTK_BUTTON(win->play_button));
            if (label && GTK_IS_LABEL(label)) {
                gtk_label_set_markup(GTK_LABEL(label),
                    "<span font_size='x-large' foreground='" DAW_COLOR_GREEN "'>▶</span>");
            }
        }
        printf("⏹ Stopped & rewound (Enter)\n");
        return TRUE;
    }

    // R = Toggle record (arm first available track and start recording)
    if ((keyval == GDK_KEY_r || keyval == GDK_KEY_R) && !(state & GDK_CONTROL_MASK)) {
        if (recording_is_active()) {
            recording_stop();
            printf("⏺ Recording stopped (R)\n");
        } else {
            // Find first armed track, or arm track 0
            int armed_track = -1;
            for (int i = 0; i < NUM_TRACKS; i++) {
                if (audio_engine_get_track_arm(win->audio_engine, i)) {
                    armed_track = i;
                    break;
                }
            }
            if (armed_track < 0) {
                // No track armed, arm track 0
                audio_engine_set_track_arm(win->audio_engine, 0, 1);
                armed_track = 0;
                printf("🔴 Armed track 1 for recording\n");
            }
            recording_start(armed_track, win->position);
            if (!audio_engine_is_playing(win->audio_engine)) {
                audio_engine_start(win->audio_engine);
            }
            printf("⏺ Recording started on track %d (R)\n", armed_track + 1);
        }
        gtk_widget_queue_draw(win->timeline_area);
        return TRUE;
    }

    // E = Open effects editor for first armed track (or track 0)
    if (keyval == GDK_KEY_e || keyval == GDK_KEY_E) {
        if (state & GDK_SHIFT_MASK) {
            // Shift+E = Master effects
            if (!win->master_effects_editor) {
                win->master_effects_editor = effects_chain_editor_new(
                    GTK_WINDOW(win->window),
                    win->audio_engine,
                    -1
                );
            }
            if (win->master_effects_editor) {
                effects_chain_editor_show(win->master_effects_editor);
                printf("🎛 Opened master effects editor (Shift+E)\n");
            }
        } else {
            // E = Track effects (find first armed track, or use track 0)
            int target_track = 0;
            for (int i = 0; i < NUM_TRACKS; i++) {
                if (audio_engine_get_track_arm(win->audio_engine, i)) {
                    target_track = i;
                    break;
                }
            }

            if (!win->effects_editors[target_track]) {
                win->effects_editors[target_track] = effects_chain_editor_new(
                    GTK_WINDOW(win->window),
                    win->audio_engine,
                    target_track
                );
            }
            if (win->effects_editors[target_track]) {
                effects_chain_editor_show(win->effects_editors[target_track]);
                printf("🎛 Opened effects editor for track %d (E key)\n", target_track + 1);
            }
        }
        return TRUE;
    }

    // I = Open instrument editor for first armed track (or track 0)
    if (keyval == GDK_KEY_i || keyval == GDK_KEY_I) {
        int target_track = 0;
        for (int i = 0; i < NUM_TRACKS; i++) {
            if (audio_engine_get_track_arm(win->audio_engine, i)) {
                target_track = i;
                break;
            }
        }

        if (!win->instrument_modals[target_track]) {
            win->instrument_modals[target_track] = instrument_modal_new(
                GTK_WINDOW(win->window),
                win->audio_engine,
                target_track
            );
        }
        if (win->instrument_modals[target_track]) {
            instrument_modal_show(win->instrument_modals[target_track]);
            printf("🎹 Opened instrument modal for track %d (I key)\n", target_track + 1);
        }
        return TRUE;
    }

    // P = Open piano roll for selected track (or first armed track)
    if (keyval == GDK_KEY_p || keyval == GDK_KEY_P) {
        int target_track = win->selected_track >= 0 ? win->selected_track : 0;
        // Prefer armed track if no selection
        if (win->selected_track < 0) {
            for (int i = 0; i < NUM_TRACKS; i++) {
                if (audio_engine_get_track_arm(win->audio_engine, i)) {
                    target_track = i;
                    break;
                }
            }
        }

        if (win->piano_roll) {
            piano_roll_set_track(win->piano_roll, target_track);
            piano_roll_show(win->piano_roll);
            printf("🎹 Opened piano roll for track %d (P key)\n", target_track + 1);
        }
        return TRUE;
    }

    // S = Split selected clip at playhead position
    if (keyval == GDK_KEY_s && !(state & GDK_CONTROL_MASK) && !(state & GDK_META_MASK)) {
        // Only split if we have a selected track with clips
        if (win->selected_track >= 0 && win->selected_track < NUM_TRACKS) {
            // Find clip at current playhead position on selected track
            int clip_count = track_get_clip_count(win->audio_engine, win->selected_track);
            for (int i = 0; i < clip_count; i++) {
                uint64_t clip_id = track_get_clip_id(win->audio_engine, win->selected_track, i);
                double start = track_get_clip_start(win->audio_engine, win->selected_track, clip_id);
                double duration = track_get_clip_duration(win->audio_engine, win->selected_track, clip_id);
                double end = start + duration;

                // Check if playhead is within this clip
                if (win->position > start && win->position < end) {
                    uint64_t new_id = track_split_clip(win->audio_engine, win->selected_track, clip_id, win->position);
                    if (new_id > 0) {
                        printf("✂ Split clip at %.2fs, created clip %llu\n", win->position, (unsigned long long)new_id);
                        gtk_widget_queue_draw(win->timeline_area);
                    }
                    break;
                }
            }
        }
        return TRUE;
    }

    // Delete/Backspace = Delete selected clip
    if (keyval == GDK_KEY_Delete || keyval == GDK_KEY_BackSpace) {
        if (win->selected_track >= 0 && win->selected_clip_id > 0) {
            if (track_remove_clip(win->audio_engine, win->selected_track, win->selected_clip_id)) {
                printf("🗑 Deleted clip %llu from track %d\n", (unsigned long long)win->selected_clip_id, win->selected_track + 1);
                win->selected_clip_id = 0;
                gtk_widget_queue_draw(win->timeline_area);
            }
        }
        return TRUE;
    }

    return FALSE;
}

static void on_window_destroy(GtkWindow *window, gpointer user_data) {
    MainWindow *win = (MainWindow *)user_data;
    (void)window;

    if (win->timer_id > 0) {
        g_source_remove(win->timer_id);
        win->timer_id = 0;
    }

    if (win->settings_modal) {
        settings_modal_destroy(win->settings_modal);
        win->settings_modal = NULL;
    }

    // Destroy instrument modals
    for (int i = 0; i < NUM_TRACKS; i++) {
        if (win->instrument_modals[i]) {
            instrument_modal_destroy(win->instrument_modals[i]);
            win->instrument_modals[i] = NULL;
        }
    }

    // Destroy effects editors
    for (int i = 0; i < NUM_TRACKS; i++) {
        if (win->effects_editors[i]) {
            effects_chain_editor_destroy(win->effects_editors[i]);
            win->effects_editors[i] = NULL;
        }
    }
    if (win->master_effects_editor) {
        effects_chain_editor_destroy(win->master_effects_editor);
        win->master_effects_editor = NULL;
    }

    // Destroy library panel
    if (win->library_panel) {
        library_panel_destroy(win->library_panel);
        win->library_panel = NULL;
    }

    // Destroy piano roll
    if (win->piano_roll) {
        piano_roll_destroy(win->piano_roll);
        win->piano_roll = NULL;
    }

    // Destroy viewport
    if (win->viewport) {
        timeline_viewport_destroy(win->viewport);
        win->viewport = NULL;
    }

    if (win->main_loop) {
        g_main_loop_quit(win->main_loop);
    }
}

// Helper: Queue redraw for all mixer widgets
static void redraw_mixer(MainWindow *win) {
    for (int i = 0; i < NUM_TRACKS; i++) {
        if (win->track_fader_meters[i] && gtk_widget_get_realized(win->track_fader_meters[i])) {
            gtk_widget_queue_draw(win->track_fader_meters[i]);
        }
    }
    if (win->master_fader_meter && gtk_widget_get_realized(win->master_fader_meter)) {
        gtk_widget_queue_draw(win->master_fader_meter);
    }
}

static void on_window_state_changed(GtkWidget *widget, GParamSpec *pspec, gpointer user_data) {
    (void)pspec;
    (void)widget;
    MainWindow *win = (MainWindow *)user_data;
    if (!win) return;

    if (win->timeline_area && gtk_widget_get_realized(win->timeline_area)) {
        gtk_widget_queue_draw(win->timeline_area);
    }
    redraw_mixer(win);
}

static void on_window_realize(GtkWidget *widget, gpointer user_data) {
    (void)widget;
    MainWindow *win = (MainWindow *)user_data;
    if (!win) return;

    if (win->timeline_area) {
        gtk_widget_queue_draw(win->timeline_area);
    }
    redraw_mixer(win);
    printf("🎨 Window realized - forcing initial render\n");
}

// =============================================================================
// Timeline Drawing - Professional DAW Layout
// =============================================================================

// Default track colors (Tokyo Night palette)
static const uint32_t DEFAULT_TRACK_COLORS[NUM_TRACKS] = {
    0x7aa2f7,  // Blue
    0xbb9af7,  // Purple
    0x7dcfff,  // Cyan
    0x9ece6a   // Green
};

// Grid line callback for viewport iteration
static void draw_grid_line_cb(int bar, int beat, double x, bool is_bar_line, void *user_data) {
    cairo_t *cr = (cairo_t *)user_data;

    if (is_bar_line) {
        // Bar lines - thicker, more visible
        cairo_set_source_rgba(cr, 0x7a/255.0, 0xa2/255.0, 0xf7/255.0, 0.5);
        cairo_set_line_width(cr, 1.5);
    } else {
        // Beat lines - subtle
        cairo_set_source_rgba(cr, 0x29/255.0, 0x2e/255.0, 0x42/255.0, 0.7);
        cairo_set_line_width(cr, 1.0);
    }

    // Just add to path, we'll stroke later
    cairo_move_to(cr, x, RULER_HEIGHT);
    cairo_line_to(cr, x, 2000);  // Will be clipped anyway
    cairo_stroke(cr);

    (void)bar;
    (void)beat;
}

// Draw the timeline ruler (bar/beat numbers at top)
static void draw_timeline_ruler(cairo_t *cr, MainWindow *win, int width) {
    if (!win || !win->viewport) return;

    const ViewportState *vp = timeline_viewport_get_state(win->viewport);
    if (!vp) return;

    // Ruler background
    cairo_set_source_rgb(cr, 0x1a/255.0, 0x1b/255.0, 0x26/255.0);
    cairo_rectangle(cr, TRACK_HEADER_WIDTH, 0, width - TRACK_HEADER_WIDTH, RULER_HEIGHT);
    cairo_fill(cr);

    // Ruler bottom border
    cairo_set_source_rgb(cr, 0x29/255.0, 0x2e/255.0, 0x42/255.0);
    cairo_set_line_width(cr, 1.0);
    cairo_move_to(cr, TRACK_HEADER_WIDTH, RULER_HEIGHT);
    cairo_line_to(cr, width, RULER_HEIGHT);
    cairo_stroke(cr);

    // Draw bar numbers
    cairo_select_font_face(cr, "Sans", CAIRO_FONT_SLANT_NORMAL, CAIRO_FONT_WEIGHT_BOLD);
    cairo_set_font_size(cr, 11);

    for (int bar = vp->visible_start_bar; bar <= vp->visible_end_bar + 1; bar++) {
        double bar_time = bar * vp->seconds_per_bar;
        double x = timeline_viewport_seconds_to_x(win->viewport, bar_time, TRACK_HEADER_WIDTH);

        if (x < TRACK_HEADER_WIDTH - 20 || x > width + 20) continue;

        // Bar tick mark
        cairo_set_source_rgb(cr, 0x56/255.0, 0x5f/255.0, 0x89/255.0);
        cairo_move_to(cr, x, RULER_HEIGHT - 6);
        cairo_line_to(cr, x, RULER_HEIGHT);
        cairo_stroke(cr);

        // Bar number
        cairo_set_source_rgb(cr, 0xa9/255.0, 0xb1/255.0, 0xd6/255.0);
        char label[16];
        snprintf(label, sizeof(label), "%d", bar + 1);
        cairo_move_to(cr, x + 4, RULER_HEIGHT - 10);
        cairo_show_text(cr, label);

        // Beat tick marks (if zoomed in enough)
        if (vp->pixels_per_beat >= 30) {
            cairo_set_source_rgb(cr, 0x29/255.0, 0x2e/255.0, 0x42/255.0);
            for (int beat = 1; beat < vp->time_sig_numerator; beat++) {
                double beat_time = bar_time + beat * vp->seconds_per_beat;
                double bx = timeline_viewport_seconds_to_x(win->viewport, beat_time, TRACK_HEADER_WIDTH);
                if (bx > TRACK_HEADER_WIDTH && bx < width) {
                    cairo_move_to(cr, bx, RULER_HEIGHT - 4);
                    cairo_line_to(cr, bx, RULER_HEIGHT);
                    cairo_stroke(cr);
                }
            }
        }
    }
}

// Draw track header (left panel with track info)
static void draw_track_header(cairo_t *cr, MainWindow *win, int track_idx, int y, int track_height) {
    if (!win) return;

    uint32_t track_color = win->track_colors[track_idx];
    if (track_color == 0) track_color = DEFAULT_TRACK_COLORS[track_idx];

    // Header background
    cairo_set_source_rgb(cr, 0x1a/255.0, 0x1b/255.0, 0x26/255.0);
    cairo_rectangle(cr, 0, y, TRACK_HEADER_WIDTH, track_height);
    cairo_fill(cr);

    // Track color indicator (4px strip on left)
    cairo_set_source_rgb(cr,
        ((track_color >> 16) & 0xFF) / 255.0,
        ((track_color >> 8) & 0xFF) / 255.0,
        (track_color & 0xFF) / 255.0);
    cairo_rectangle(cr, 0, y, 4, track_height);
    cairo_fill(cr);

    // Track number
    cairo_set_source_rgb(cr, 0xc0/255.0, 0xca/255.0, 0xf5/255.0);
    cairo_select_font_face(cr, "Sans", CAIRO_FONT_SLANT_NORMAL, CAIRO_FONT_WEIGHT_BOLD);
    cairo_set_font_size(cr, 13);
    char track_num[8];
    snprintf(track_num, sizeof(track_num), "%d", track_idx + 1);
    cairo_move_to(cr, 10, y + 16);
    cairo_show_text(cr, track_num);

    // Instrument name
    cairo_select_font_face(cr, "Sans", CAIRO_FONT_SLANT_NORMAL, CAIRO_FONT_WEIGHT_NORMAL);
    cairo_set_font_size(cr, 10);

    const char *inst_name = NULL;
    if (win->audio_engine && audio_engine_track_has_instrument(win->audio_engine, track_idx)) {
        inst_name = audio_engine_get_track_instrument_name(win->audio_engine, track_idx);
    }

    if (inst_name) {
        cairo_set_source_rgb(cr, 0x7d/255.0, 0xcf/255.0, 0xff/255.0);
        // Truncate long names
        char truncated[14];
        strncpy(truncated, inst_name, 13);
        truncated[13] = '\0';
        if (strlen(inst_name) > 13) {
            truncated[10] = '.';
            truncated[11] = '.';
            truncated[12] = '.';
        }
        cairo_move_to(cr, 10, y + 30);
        cairo_show_text(cr, truncated);
    } else {
        // Check if track has audio clips
        int clip_count = 0;
        if (win->audio_engine) {
            clip_count = track_get_clip_count(win->audio_engine, track_idx);
        }

        if (clip_count > 0) {
            // Show "Audio X" for tracks with recordings
            cairo_set_source_rgb(cr, 0x9e/255.0, 0xce/255.0, 0x6a/255.0);  // Green color for audio
            cairo_move_to(cr, 10, y + 30);
            char audio_label[16];
            snprintf(audio_label, sizeof(audio_label), "Audio %d", track_idx + 1);
            cairo_show_text(cr, audio_label);
        } else {
            cairo_set_source_rgb(cr, 0x56/255.0, 0x5f/255.0, 0x89/255.0);
            cairo_move_to(cr, 10, y + 30);
            cairo_show_text(cr, "Empty");
        }
    }

    // Status indicators row (at bottom of header)
    int indicator_y = y + track_height - 14;
    int indicator_x = 10;

    // Armed indicator (red dot)
    if (win->audio_engine && audio_engine_get_track_arm(win->audio_engine, track_idx)) {
        cairo_set_source_rgb(cr, 0xf7/255.0, 0x76/255.0, 0x8e/255.0);
        cairo_arc(cr, indicator_x + 5, indicator_y, 5, 0, 2 * M_PI);
        cairo_fill(cr);
        indicator_x += 16;
    }

    // Mute indicator
    if (win->audio_engine && audio_engine_get_track_mute(win->audio_engine, track_idx)) {
        cairo_set_source_rgb(cr, 0xe0/255.0, 0xaf/255.0, 0x68/255.0);
        cairo_select_font_face(cr, "Sans", CAIRO_FONT_SLANT_NORMAL, CAIRO_FONT_WEIGHT_BOLD);
        cairo_set_font_size(cr, 9);
        cairo_move_to(cr, indicator_x, indicator_y + 3);
        cairo_show_text(cr, "M");
        indicator_x += 14;
    }

    // Solo indicator
    if (win->audio_engine && audio_engine_get_track_solo(win->audio_engine, track_idx)) {
        cairo_set_source_rgb(cr, 0x9e/255.0, 0xce/255.0, 0x6a/255.0);
        cairo_select_font_face(cr, "Sans", CAIRO_FONT_SLANT_NORMAL, CAIRO_FONT_WEIGHT_BOLD);
        cairo_set_font_size(cr, 9);
        cairo_move_to(cr, indicator_x, indicator_y + 3);
        cairo_show_text(cr, "S");
    }

    // Mini meter (read-only level display)
    if (win->audio_engine) {
        float level = win->track_meters[track_idx];
        int meter_width = TRACK_HEADER_WIDTH - 20;
        int meter_x = 10;
        int meter_y = y + 38;
        int meter_h = 4;

        // Meter background
        cairo_set_source_rgb(cr, 0x16/255.0, 0x16/255.0, 0x1e/255.0);
        cairo_rectangle(cr, meter_x, meter_y, meter_width, meter_h);
        cairo_fill(cr);

        // Meter fill
        int fill_width = (int)(level * meter_width);
        if (fill_width > 0) {
            if (level > 0.9) {
                cairo_set_source_rgb(cr, 0xf7/255.0, 0x76/255.0, 0x8e/255.0);  // Red for hot
            } else if (level > 0.7) {
                cairo_set_source_rgb(cr, 0xe0/255.0, 0xaf/255.0, 0x68/255.0);  // Yellow
            } else {
                cairo_set_source_rgb(cr, 0x9e/255.0, 0xce/255.0, 0x6a/255.0);  // Green
            }
            cairo_rectangle(cr, meter_x, meter_y, fill_width, meter_h);
            cairo_fill(cr);
        }
    }

    // Header border
    cairo_set_source_rgb(cr, 0x29/255.0, 0x2e/255.0, 0x42/255.0);
    cairo_set_line_width(cr, 1.0);
    cairo_rectangle(cr, 0, y, TRACK_HEADER_WIDTH, track_height);
    cairo_stroke(cr);
}

// Draw clip on timeline
static void draw_clip(cairo_t *cr, MainWindow *win, int track_idx,
                      uint64_t clip_id, double clip_start, double clip_duration,
                      const char *name, uint32_t color,
                      int y, int track_height, bool selected) {
    if (!win || !win->viewport) return;

    // Convert time to screen coordinates
    double x1 = timeline_viewport_seconds_to_x(win->viewport, clip_start, TRACK_HEADER_WIDTH);
    double x2 = timeline_viewport_seconds_to_x(win->viewport, clip_start + clip_duration, TRACK_HEADER_WIDTH);

    // Skip if not visible
    int width = gtk_widget_get_width(win->timeline_area);
    if (x2 < TRACK_HEADER_WIDTH || x1 > width) return;

    // Calculate visible portion of clip for waveform
    double visible_start_time = clip_start;
    double visible_end_time = clip_start + clip_duration;

    // Clip to visible area
    if (x1 < TRACK_HEADER_WIDTH) {
        visible_start_time = timeline_viewport_x_to_seconds(win->viewport, TRACK_HEADER_WIDTH, TRACK_HEADER_WIDTH);
        x1 = TRACK_HEADER_WIDTH;
    }
    if (x2 > width) {
        visible_end_time = timeline_viewport_x_to_seconds(win->viewport, width, TRACK_HEADER_WIDTH);
    }

    double clip_width = x2 - x1;
    if (clip_width < 2) return;  // Too small to draw

    int clip_y = y + 4;
    int clip_h = track_height - 8;

    // Clip body with rounded corners
    double radius = 4.0;
    cairo_new_sub_path(cr);
    cairo_arc(cr, x1 + clip_width - radius, clip_y + radius, radius, -M_PI/2, 0);
    cairo_arc(cr, x1 + clip_width - radius, clip_y + clip_h - radius, radius, 0, M_PI/2);
    cairo_arc(cr, x1 + radius, clip_y + clip_h - radius, radius, M_PI/2, M_PI);
    cairo_arc(cr, x1 + radius, clip_y + radius, radius, M_PI, 3*M_PI/2);
    cairo_close_path(cr);

    // Fill with track/clip color
    cairo_set_source_rgba(cr,
        ((color >> 16) & 0xFF) / 255.0,
        ((color >> 8) & 0xFF) / 255.0,
        (color & 0xFF) / 255.0,
        0.6);
    cairo_fill_preserve(cr);

    // Border
    if (selected) {
        cairo_set_source_rgb(cr, 1.0, 1.0, 1.0);
        cairo_set_line_width(cr, 2.0);
    } else {
        cairo_set_source_rgba(cr,
            ((color >> 16) & 0xFF) / 255.0 * 1.3,
            ((color >> 8) & 0xFF) / 255.0 * 1.3,
            (color & 0xFF) / 255.0 * 1.3,
            0.8);
        cairo_set_line_width(cr, 1.0);
    }
    cairo_stroke(cr);

    // Draw trim handles for selected clips
    if (selected && clip_width > 30) {
        const double HANDLE_WIDTH = 6.0;
        const double HANDLE_MARGIN = 2.0;

        // Left trim handle
        cairo_set_source_rgba(cr, 1.0, 1.0, 1.0, 0.8);
        cairo_rectangle(cr, x1 + HANDLE_MARGIN, clip_y + HANDLE_MARGIN,
                       HANDLE_WIDTH, clip_h - 2 * HANDLE_MARGIN);
        cairo_fill(cr);

        // Right trim handle
        cairo_rectangle(cr, x1 + clip_width - HANDLE_WIDTH - HANDLE_MARGIN,
                       clip_y + HANDLE_MARGIN, HANDLE_WIDTH, clip_h - 2 * HANDLE_MARGIN);
        cairo_fill(cr);
    }

    // Clip name (if wide enough)
    if (clip_width > 40 && name) {
        cairo_set_source_rgb(cr, 0xc0/255.0, 0xca/255.0, 0xf5/255.0);
        cairo_select_font_face(cr, "Sans", CAIRO_FONT_SLANT_NORMAL, CAIRO_FONT_WEIGHT_NORMAL);
        cairo_set_font_size(cr, 10);

        // Truncate name if needed
        char display_name[32];
        int max_chars = (int)(clip_width / 7);
        if (max_chars > 30) max_chars = 30;
        strncpy(display_name, name, max_chars);
        display_name[max_chars] = '\0';

        cairo_move_to(cr, x1 + 6, clip_y + 14);
        cairo_show_text(cr, display_name);
    }

    // Waveform visualization
    if (clip_width > 20) {
        cairo_save(cr);
        cairo_rectangle(cr, x1 + 2, clip_y + 18, clip_width - 4, clip_h - 22);
        cairo_clip(cr);

        // Calculate number of peaks needed (1 per 2 pixels)
        int num_peaks = (int)(clip_width / 2);
        if (num_peaks > 256) num_peaks = 256;
        if (num_peaks < 4) num_peaks = 4;

        // Buffer for peaks data (min/max pairs)
        float peaks[512];  // 256 peaks * 2 values

        // Get peaks from the audio engine
        int peaks_received = 0;
        if (win->audio_engine && clip_id > 0) {
            peaks_received = track_get_clip_peaks(
                win->audio_engine, track_idx, clip_id,
                visible_start_time, visible_end_time,
                num_peaks, peaks
            );
        }

        // Draw waveform
        cairo_set_source_rgba(cr, 0xc0/255.0, 0xca/255.0, 0xf5/255.0, 0.5);
        int center_y = clip_y + clip_h / 2 + 6;
        int wave_height = (clip_h - 24) / 2;

        if (peaks_received > 0) {
            // Draw actual waveform from peak data
            double step = (clip_width - 8) / peaks_received;
            for (int i = 0; i < peaks_received; i++) {
                double px = x1 + 4 + (i * step);
                float min_val = peaks[i * 2];
                float max_val = peaks[i * 2 + 1];

                // Scale to wave height
                double y_min = center_y - (max_val * wave_height);
                double y_max = center_y - (min_val * wave_height);

                cairo_move_to(cr, px, y_min);
                cairo_line_to(cr, px, y_max);
            }
        } else {
            // Fallback: draw placeholder waveform
            for (int i = 0; i < num_peaks; i++) {
                double px = x1 + 4 + (i * (clip_width - 8) / num_peaks);
                double t = (double)i / num_peaks;
                double phase = t * 20.0 + clip_start * 5.0;
                double amplitude = 0.3 + 0.5 * fabs(sin(phase));

                cairo_move_to(cr, px, center_y - amplitude * wave_height);
                cairo_line_to(cr, px, center_y + amplitude * wave_height);
            }
        }

        cairo_set_line_width(cr, 1.0);
        cairo_stroke(cr);

        cairo_restore(cr);
    }
}

// Draw a MIDI/instrument clip with piano roll style
static void draw_midi_clip(cairo_t *cr, MainWindow *win, int track_idx,
                           uint64_t clip_id, double clip_start, double clip_duration,
                           const char *name, uint32_t color,
                           int y, int track_height, bool selected) {
    if (!win || !win->viewport) return;

    // Convert time to screen coordinates
    double x1 = timeline_viewport_seconds_to_x(win->viewport, clip_start, TRACK_HEADER_WIDTH);
    double x2 = timeline_viewport_seconds_to_x(win->viewport, clip_start + clip_duration, TRACK_HEADER_WIDTH);

    int width = gtk_widget_get_width(win->timeline_area);
    if (x2 < TRACK_HEADER_WIDTH || x1 > width) return;
    if (x1 < TRACK_HEADER_WIDTH) x1 = TRACK_HEADER_WIDTH;

    double clip_width = x2 - x1;
    if (clip_width < 2) return;

    int clip_y = y + 4;
    int clip_h = track_height - 8;

    // Clip body with rounded corners
    double radius = 4.0;
    cairo_new_sub_path(cr);
    cairo_arc(cr, x1 + clip_width - radius, clip_y + radius, radius, -M_PI/2, 0);
    cairo_arc(cr, x1 + clip_width - radius, clip_y + clip_h - radius, radius, 0, M_PI/2);
    cairo_arc(cr, x1 + radius, clip_y + clip_h - radius, radius, M_PI/2, M_PI);
    cairo_arc(cr, x1 + radius, clip_y + radius, radius, M_PI, 3*M_PI/2);
    cairo_close_path(cr);

    // Fill with slightly transparent color
    cairo_set_source_rgba(cr,
        ((color >> 16) & 0xFF) / 255.0,
        ((color >> 8) & 0xFF) / 255.0,
        (color & 0xFF) / 255.0,
        0.5);
    cairo_fill_preserve(cr);

    // Border
    if (selected) {
        cairo_set_source_rgb(cr, 1.0, 1.0, 1.0);
        cairo_set_line_width(cr, 2.0);
    } else {
        cairo_set_source_rgba(cr,
            ((color >> 16) & 0xFF) / 255.0 * 1.3,
            ((color >> 8) & 0xFF) / 255.0 * 1.3,
            (color & 0xFF) / 255.0 * 1.3,
            0.8);
        cairo_set_line_width(cr, 1.0);
    }
    cairo_stroke(cr);

    // Clip name
    if (clip_width > 40 && name) {
        cairo_set_source_rgb(cr, 0xc0/255.0, 0xca/255.0, 0xf5/255.0);
        cairo_select_font_face(cr, "Sans", CAIRO_FONT_SLANT_NORMAL, CAIRO_FONT_WEIGHT_NORMAL);
        cairo_set_font_size(cr, 10);

        char display_name[32];
        int max_chars = (int)(clip_width / 7);
        if (max_chars > 30) max_chars = 30;
        strncpy(display_name, name, max_chars);
        display_name[max_chars] = '\0';

        cairo_move_to(cr, x1 + 6, clip_y + 14);
        cairo_show_text(cr, display_name);
    }

    // Draw piano roll style visualization
    if (clip_width > 20 && clip_h > 30) {
        cairo_save(cr);
        cairo_rectangle(cr, x1 + 2, clip_y + 18, clip_width - 4, clip_h - 22);
        cairo_clip(cr);

        // Piano roll grid lines (representing octaves)
        cairo_set_source_rgba(cr, 0.3, 0.3, 0.4, 0.3);
        cairo_set_line_width(cr, 0.5);

        int roll_height = clip_h - 22;
        int note_range = 24;  // 2 octaves visible
        double note_height = (double)roll_height / note_range;

        // Draw horizontal grid lines for notes
        for (int i = 0; i <= note_range; i += 12) {
            double line_y = clip_y + 18 + (i * note_height);
            cairo_move_to(cr, x1 + 2, line_y);
            cairo_line_to(cr, x1 + clip_width - 2, line_y);
        }
        cairo_stroke(cr);

        // Draw some placeholder MIDI notes (visual interest)
        cairo_set_source_rgba(cr,
            ((color >> 16) & 0xFF) / 255.0,
            ((color >> 8) & 0xFF) / 255.0,
            (color & 0xFF) / 255.0,
            0.8);

        // Generate pseudo-random notes based on clip position
        int num_notes = (int)(clip_width / 20);
        if (num_notes > 16) num_notes = 16;
        if (num_notes < 3) num_notes = 3;

        double note_width_px = (clip_width - 8) / (num_notes + 2);

        for (int i = 0; i < num_notes; i++) {
            // Pseudo-random note placement
            double seed = clip_start * 10.0 + i * 1.7 + track_idx * 3.3;
            int note_offset = (int)(fabs(sin(seed)) * 20) % note_range;
            double note_len = 0.5 + fabs(cos(seed * 1.3)) * 0.5;

            double nx = x1 + 4 + (i + 0.5) * note_width_px;
            double ny = clip_y + 18 + (note_range - note_offset - 1) * note_height;
            double nw = note_width_px * note_len * 0.8;
            double nh = note_height * 0.8;

            // Draw note rectangle with rounded corners
            double nr = 2.0;
            if (nw > 4 && nh > 4) {
                cairo_new_sub_path(cr);
                cairo_arc(cr, nx + nw - nr, ny + nr, nr, -M_PI/2, 0);
                cairo_arc(cr, nx + nw - nr, ny + nh - nr, nr, 0, M_PI/2);
                cairo_arc(cr, nx + nr, ny + nh - nr, nr, M_PI/2, M_PI);
                cairo_arc(cr, nx + nr, ny + nr, nr, M_PI, 3*M_PI/2);
                cairo_close_path(cr);
                cairo_fill(cr);
            } else {
                cairo_rectangle(cr, nx, ny, nw, nh);
                cairo_fill(cr);
            }
        }

        cairo_restore(cr);
    }

    (void)clip_id;
}

// Draw track content area (clips)
// Draw recording preview clip (pulsing red with live waveform)
static void draw_recording_preview(cairo_t *cr, MainWindow *win, int track_idx, int y, int track_height, int width) {
    if (!recording_is_active()) return;
    if (recording_get_target_track() != track_idx) return;

    double start_time = recording_get_start_time();
    double duration = recording_get_duration();
    if (duration < 0.01) duration = 0.1;  // Minimum visible width

    double x_start = timeline_viewport_seconds_to_x(win->viewport, start_time, TRACK_HEADER_WIDTH);
    double x_end = timeline_viewport_seconds_to_x(win->viewport, start_time + duration, TRACK_HEADER_WIDTH);

    // Clip to visible area
    if (x_end < TRACK_HEADER_WIDTH || x_start > width) return;
    if (x_start < TRACK_HEADER_WIDTH) x_start = TRACK_HEADER_WIDTH;

    double clip_width = x_end - x_start;
    if (clip_width < 2) clip_width = 2;

    int clip_y = y + 4;
    int clip_height = track_height - 8;

    // Pulsing effect based on time
    double pulse = 0.6 + 0.4 * sin(g_get_monotonic_time() / 300000.0);

    // Recording clip background (dark red with pulse)
    cairo_set_source_rgba(cr, 0.8 * pulse, 0.2, 0.2, 0.7);
    cairo_rectangle(cr, x_start, clip_y, clip_width, clip_height);
    cairo_fill(cr);

    // Draw live waveform preview
    if (clip_width > 10) {
        int max_peaks = (int)clip_width;
        if (max_peaks > 256) max_peaks = 256;

        float peaks[256];
        uint32_t num_peaks = recording_get_peaks(peaks, max_peaks);

        if (num_peaks > 0) {
            cairo_set_source_rgba(cr, 1.0, 0.4, 0.4, 0.9);
            cairo_set_line_width(cr, 1.0);

            double peak_width = clip_width / num_peaks;
            double center_y = clip_y + clip_height / 2.0;
            double max_amp = (clip_height / 2.0) - 2;

            for (uint32_t i = 0; i < num_peaks; i++) {
                double px = x_start + i * peak_width;
                double amp = peaks[i] * max_amp;
                if (amp < 1) amp = 1;

                cairo_move_to(cr, px, center_y - amp);
                cairo_line_to(cr, px, center_y + amp);
            }
            cairo_stroke(cr);
        }
    }

    // Recording clip border (bright red)
    cairo_set_source_rgb(cr, 0.95, 0.3, 0.3);
    cairo_set_line_width(cr, 2.0);
    cairo_rectangle(cr, x_start, clip_y, clip_width, clip_height);
    cairo_stroke(cr);

    // Recording indicator text
    cairo_set_source_rgb(cr, 1.0, 1.0, 1.0);
    cairo_select_font_face(cr, "Sans", CAIRO_FONT_SLANT_NORMAL, CAIRO_FONT_WEIGHT_BOLD);
    cairo_set_font_size(cr, 10);

    char label[32];
    snprintf(label, sizeof(label), "● REC %.1fs", duration);
    cairo_move_to(cr, x_start + 4, clip_y + 12);
    cairo_show_text(cr, label);
}

static void draw_track_content(cairo_t *cr, MainWindow *win, int track_idx, int y, int track_height, int width) {
    if (!win || !win->viewport) return;

    // Track background with alternating shade
    if (track_idx % 2 == 0) {
        cairo_set_source_rgb(cr, 0x16/255.0, 0x16/255.0, 0x1e/255.0);
    } else {
        cairo_set_source_rgb(cr, 0x18/255.0, 0x18/255.0, 0x22/255.0);
    }
    cairo_rectangle(cr, TRACK_HEADER_WIDTH, y, width - TRACK_HEADER_WIDTH, track_height);
    cairo_fill(cr);

    // Track separator line
    cairo_set_source_rgb(cr, 0x29/255.0, 0x2e/255.0, 0x42/255.0);
    cairo_set_line_width(cr, 1.0);
    cairo_move_to(cr, TRACK_HEADER_WIDTH, y + track_height);
    cairo_line_to(cr, width, y + track_height);
    cairo_stroke(cr);

    // Draw recording preview if this track is being recorded to
    draw_recording_preview(cr, win, track_idx, y, track_height, width);

    if (!win->audio_engine) return;

    uint32_t track_color = win->track_colors[track_idx];
    if (track_color == 0) track_color = DEFAULT_TRACK_COLORS[track_idx];

    // Check if track has an instrument (MIDI mode)
    bool is_instrument_track = audio_engine_track_has_instrument(win->audio_engine, track_idx);

    // Get clips from the audio engine
    int clip_count = track_get_clip_count(win->audio_engine, track_idx);

    if (clip_count > 0) {
        // Draw all clips on this track
        for (int i = 0; i < clip_count; i++) {
            uint64_t clip_id = track_get_clip_id(win->audio_engine, track_idx, i);
            if (clip_id == 0) continue;

            double clip_start = track_get_clip_start(win->audio_engine, track_idx, clip_id);
            double clip_duration = track_get_clip_duration(win->audio_engine, track_idx, clip_id);
            const char *clip_name = track_get_clip_name(win->audio_engine, track_idx, clip_id);
            uint32_t clip_color = track_get_clip_color(win->audio_engine, track_idx, clip_id);

            if (clip_color == 0x7aa2f7) clip_color = track_color;

            bool is_selected = (win->selected_track == track_idx && win->selected_clip_id == clip_id);

            // Use MIDI clip drawing for instrument tracks
            if (is_instrument_track) {
                draw_midi_clip(cr, win, track_idx, clip_id, clip_start, clip_duration,
                              clip_name, clip_color, y, track_height, is_selected);
            } else {
                draw_clip(cr, win, track_idx, clip_id, clip_start, clip_duration,
                          clip_name, clip_color, y, track_height, is_selected);
            }
        }
    } else if (is_instrument_track) {
        // Show MIDI clip for instrument tracks using actual clip position
        const ViewportState *vp = timeline_viewport_get_state(win->viewport);
        if (!vp) return;

        // Get MIDI clip position and duration in beats, convert to seconds
        double clip_start_beat = midi_clip_get_start_beat(track_idx);
        double clip_duration_beats = midi_clip_get_clip_duration(track_idx);
        double clip_start = clip_start_beat * vp->seconds_per_beat;
        double clip_duration = clip_duration_beats * vp->seconds_per_beat;

        const char *inst_name = audio_engine_get_track_instrument_name(win->audio_engine, track_idx);
        bool is_selected = (win->selected_track == track_idx);

        draw_midi_clip(cr, win, track_idx, 0, clip_start, clip_duration,
                      inst_name ? inst_name : "MIDI", track_color,
                      y, track_height, is_selected);
    }
}

// Draw playhead
static void draw_playhead(cairo_t *cr, MainWindow *win, int height) {
    if (!win || !win->viewport) return;

    double playhead_x = timeline_viewport_seconds_to_x(win->viewport, win->position, TRACK_HEADER_WIDTH);

    int width = gtk_widget_get_width(win->timeline_area);
    if (playhead_x < TRACK_HEADER_WIDTH - 10 || playhead_x > width + 10) return;

    // Playhead line
    cairo_set_source_rgb(cr, 0xf7/255.0, 0x76/255.0, 0x8e/255.0);
    cairo_set_line_width(cr, 2.0);
    cairo_move_to(cr, playhead_x, 0);
    cairo_line_to(cr, playhead_x, height);
    cairo_stroke(cr);

    // Playhead handle (in ruler)
    cairo_move_to(cr, playhead_x - 7, 0);
    cairo_line_to(cr, playhead_x + 7, 0);
    cairo_line_to(cr, playhead_x + 7, 6);
    cairo_line_to(cr, playhead_x, RULER_HEIGHT - 4);
    cairo_line_to(cr, playhead_x - 7, 6);
    cairo_close_path(cr);
    cairo_fill(cr);
}

// Main timeline drawing function
static void draw_timeline(GtkDrawingArea *area, cairo_t *cr, int width, int height, gpointer user_data) {
    (void)area;

    if (!user_data || !cr || width <= 0 || height <= 0) return;

    MainWindow *win = (MainWindow *)user_data;

    // Ensure viewport exists and is updated
    if (!win->viewport) return;

    timeline_viewport_set_viewport_width(win->viewport, width, TRACK_HEADER_WIDTH);
    timeline_viewport_set_tempo(win->viewport, win->bpm, win->time_sig_numerator, win->time_sig_denominator);

    // 1. Background
    cairo_set_source_rgb(cr, 0x16/255.0, 0x16/255.0, 0x1e/255.0);
    cairo_rectangle(cr, 0, 0, width, height);
    cairo_fill(cr);

    // 2. Calculate track layout
    int content_height = height - RULER_HEIGHT;
    int track_height = content_height / NUM_TRACKS;
    if (track_height < MIN_TRACK_HEIGHT) track_height = MIN_TRACK_HEIGHT;

    // 3. Draw grid lines (behind everything)
    cairo_save(cr);
    cairo_rectangle(cr, TRACK_HEADER_WIDTH, RULER_HEIGHT, width - TRACK_HEADER_WIDTH, height - RULER_HEIGHT);
    cairo_clip(cr);
    timeline_viewport_foreach_grid_line(win->viewport, TRACK_HEADER_WIDTH, width, draw_grid_line_cb, cr);
    cairo_restore(cr);

    // 4. Draw track content areas (clips, etc.)
    for (int i = 0; i < NUM_TRACKS; i++) {
        int y = RULER_HEIGHT + i * track_height;
        draw_track_content(cr, win, i, y, track_height, width);
    }

    // 5. Draw track headers (on top of content)
    for (int i = 0; i < NUM_TRACKS; i++) {
        int y = RULER_HEIGHT + i * track_height;
        draw_track_header(cr, win, i, y, track_height);
    }

    // 6. Draw timeline ruler
    draw_timeline_ruler(cr, win, width);

    // 7. Draw header area background for ruler corner
    cairo_set_source_rgb(cr, 0x1a/255.0, 0x1b/255.0, 0x26/255.0);
    cairo_rectangle(cr, 0, 0, TRACK_HEADER_WIDTH, RULER_HEIGHT);
    cairo_fill(cr);

    // 8. Draw vertical separator
    cairo_set_source_rgb(cr, 0x29/255.0, 0x2e/255.0, 0x42/255.0);
    cairo_set_line_width(cr, 1.0);
    cairo_move_to(cr, TRACK_HEADER_WIDTH, 0);
    cairo_line_to(cr, TRACK_HEADER_WIDTH, height);
    cairo_stroke(cr);

    // 9. Draw playhead (on top of everything)
    draw_playhead(cr, win, height);

    // Check for cairo errors
    cairo_status_t status = cairo_status(cr);
    if (status != CAIRO_STATUS_SUCCESS) {
        fprintf(stderr, "Cairo error in draw_timeline: %s\n", cairo_status_to_string(status));
    }
}

// =============================================================================
// End Timeline Drawing
// =============================================================================

// Track fader+meter drawing (Logic Pro style)
static void draw_fader_meter(GtkDrawingArea *area, cairo_t *cr, int width, int height, gpointer user_data) {
    if (!cr || width <= 0 || height <= 0 || !user_data) return;

    MainWindow *win = (MainWindow *)user_data;

    // Find track index
    int track = -1;
    for (int i = 0; i < NUM_TRACKS; i++) {
        if ((void *)area == (void *)win->track_fader_meters[i]) {
            track = i;
            break;
        }
    }
    if (track < 0) return;

    fill_background(cr, width, height);
    draw_meter_bar(cr, 0, 2, width, height - 4, win->track_meters[track], 0.7);
    draw_fader_handle(cr, (int)(win->track_gains[track] * width), height, &COLOR_CYAN);

    // Fader handle cap (small triangle)
    int fader_x = (int)(win->track_gains[track] * width);
    cairo_set_source_rgb(cr, COLOR_FG.r, COLOR_FG.g, COLOR_FG.b);
    cairo_move_to(cr, fader_x, height / 2 - 4);
    cairo_line_to(cr, fader_x - 4, height / 2);
    cairo_line_to(cr, fader_x, height / 2 + 4);
    cairo_close_path(cr);
    cairo_fill(cr);

    draw_border(cr, width, height);
}

// Master fader+meter drawing (stereo, Logic Pro style)
static void draw_master_fader_meter(GtkDrawingArea *area, cairo_t *cr, int width, int height, gpointer user_data) {
    (void)area;
    if (!cr || width <= 0 || height <= 0 || !user_data) return;

    MainWindow *win = (MainWindow *)user_data;

    fill_background(cr, width, height);

    // Stereo meters (L on top, R on bottom)
    int meter_h = (height - 2) / 2;
    draw_meter_bar(cr, 0, 1, width, meter_h - 1, win->master_meter_left, 0.7);
    draw_meter_bar(cr, 0, meter_h + 1, width, meter_h - 1, win->master_meter_right, 0.7);

    draw_fader_handle(cr, (int)(win->master_gain * width), height, &COLOR_PURPLE);
    draw_border(cr, width, height);
}

// Helper: Update fader gain from x position and redraw
static void update_fader_gain(MainWindow *win, GtkWidget *widget, double x) {
    int width = gtk_widget_get_width(widget);
    if (width <= 0) return;

    float gain = clamp_gain((float)x / width);

    // Check track faders
    for (int i = 0; i < NUM_TRACKS; i++) {
        if (widget == win->track_fader_meters[i]) {
            win->track_gains[i] = gain;
            if (win->audio_engine) {
                audio_engine_set_track_gain(win->audio_engine, i, gain);
            }
            gtk_widget_queue_draw(widget);
            return;
        }
    }

    // Check master fader
    if (widget == win->master_fader_meter) {
        win->master_gain = gain;
        if (win->audio_engine) {
            audio_engine_set_master_gain(win->audio_engine, gain);
        }
        gtk_widget_queue_draw(widget);
    }
}

// Unified fader drag handler (handles both begin and update)
static void on_fader_drag(GtkGestureDrag *gesture, double x, double y, gpointer user_data) {
    (void)y;
    MainWindow *win = (MainWindow *)user_data;
    GtkWidget *widget = gtk_event_controller_get_widget(GTK_EVENT_CONTROLLER(gesture));
    update_fader_gain(win, widget, x);
}

static void on_fader_drag_update(GtkGestureDrag *gesture, double offset_x, double offset_y, gpointer user_data) {
    (void)offset_y;
    MainWindow *win = (MainWindow *)user_data;
    GtkWidget *widget = gtk_event_controller_get_widget(GTK_EVENT_CONTROLLER(gesture));

    double start_x, start_y;
    gtk_gesture_drag_get_start_point(gesture, &start_x, &start_y);
    update_fader_gain(win, widget, start_x + offset_x);
}

// Pan knob drawing (RX/Ableton style circular knob)
static void draw_pan_knob(GtkDrawingArea *area, cairo_t *cr, int width, int height, gpointer user_data) {
    if (!cr || width <= 0 || height <= 0 || !user_data) return;

    MainWindow *win = (MainWindow *)user_data;

    // Find track index
    int track_idx = -1;
    for (int i = 0; i < NUM_TRACKS; i++) {
        if ((void *)area == (void *)win->track_pan_knobs[i]) {
            track_idx = i;
            break;
        }
    }
    if (track_idx < 0) return;

    float pan = win->track_pans[track_idx];

    // Knob dimensions
    double cx = width / 2.0;
    double cy = height / 2.0;
    double radius = fmin(width, height) / 2.0 - 2;

    // Background circle (dark)
    cairo_set_source_rgb(cr, 0.12, 0.12, 0.14);
    cairo_arc(cr, cx, cy, radius, 0, 2 * M_PI);
    cairo_fill(cr);

    // Track arc (shows range)
    cairo_set_source_rgb(cr, 0.25, 0.25, 0.28);
    cairo_set_line_width(cr, 3.0);
    cairo_arc(cr, cx, cy, radius - 2, 0.75 * M_PI, 2.25 * M_PI);
    cairo_stroke(cr);

    // Value arc (shows pan position)
    double start_angle = 1.5 * M_PI;  // 12 o'clock (center)
    double end_angle = start_angle + pan * 0.75 * M_PI;  // pan * 135 degrees

    if (pan != 0.0f) {
        if (pan > 0) {
            cairo_set_source_rgb(cr, 0.48, 0.63, 0.97);  // Blue for right
        } else {
            cairo_set_source_rgb(cr, 0.62, 0.82, 0.42);  // Green for left
        }
        cairo_set_line_width(cr, 3.0);
        if (pan > 0) {
            cairo_arc(cr, cx, cy, radius - 2, start_angle, end_angle);
        } else {
            cairo_arc_negative(cr, cx, cy, radius - 2, start_angle, end_angle);
        }
        cairo_stroke(cr);
    }

    // Knob indicator line
    double indicator_angle = start_angle + pan * 0.75 * M_PI;
    double inner_r = radius * 0.3;
    double outer_r = radius * 0.8;

    cairo_set_source_rgb(cr, 0.9, 0.9, 0.92);
    cairo_set_line_width(cr, 2.0);
    cairo_move_to(cr, cx + inner_r * cos(indicator_angle), cy + inner_r * sin(indicator_angle));
    cairo_line_to(cr, cx + outer_r * cos(indicator_angle), cy + outer_r * sin(indicator_angle));
    cairo_stroke(cr);

    // Center dot
    cairo_set_source_rgb(cr, 0.35, 0.35, 0.38);
    cairo_arc(cr, cx, cy, 3, 0, 2 * M_PI);
    cairo_fill(cr);
}

// Store initial pan value when drag starts
static float pan_drag_start_value[NUM_TRACKS] = {0};

// Pan knob drag handler - store initial value on drag begin
static void on_pan_drag(GtkGestureDrag *gesture, double x, double y, gpointer user_data) {
    (void)x;
    (void)y;
    MainWindow *win = (MainWindow *)user_data;
    GtkWidget *widget = gtk_event_controller_get_widget(GTK_EVENT_CONTROLLER(gesture));

    // Find track index and store current pan value
    for (int i = 0; i < NUM_TRACKS; i++) {
        if (widget == win->track_pan_knobs[i]) {
            pan_drag_start_value[i] = win->track_pans[i];
            break;
        }
    }
}

static void on_pan_drag_update(GtkGestureDrag *gesture, double offset_x, double offset_y, gpointer user_data) {
    (void)offset_y;
    MainWindow *win = (MainWindow *)user_data;
    GtkWidget *widget = gtk_event_controller_get_widget(GTK_EVENT_CONTROLLER(gesture));

    // Find track index
    int track_idx = -1;
    for (int i = 0; i < NUM_TRACKS; i++) {
        if (widget == win->track_pan_knobs[i]) {
            track_idx = i;
            break;
        }
    }
    if (track_idx < 0) return;

    // Calculate pan from drag offset (150px = full range, much less sensitive)
    float pan = pan_drag_start_value[track_idx] + (float)(offset_x / 150.0);
    if (pan < -1.0f) pan = -1.0f;
    if (pan > 1.0f) pan = 1.0f;

    win->track_pans[track_idx] = pan;
    if (win->audio_engine) {
        audio_engine_set_track_pan(win->audio_engine, track_idx, pan);
    }
    gtk_widget_queue_draw(widget);
}

// =============================================================================
// Timeline Context Menu
// =============================================================================

static void on_context_add_clip(GtkButton *button, gpointer user_data) {
    (void)button;
    MainWindow *win = (MainWindow *)user_data;
    if (!win) return;

    // Add a 4-beat clip at the click position
    const ViewportState *vp = timeline_viewport_get_state(win->viewport);
    double duration = 4.0 * vp->seconds_per_beat;  // 4 beats

    // Snap to beat grid
    double snap_time = win->context_click_time;
    snap_time = round(snap_time / vp->seconds_per_beat) * vp->seconds_per_beat;

    // Generate a clip name
    char name[32];
    snprintf(name, sizeof(name), "Clip %d", track_get_clip_count(win->audio_engine, win->context_click_track) + 1);

    // Use track color
    uint32_t color = win->track_colors[win->context_click_track];

    uint64_t clip_id = track_add_clip(win->audio_engine, win->context_click_track,
                                       snap_time, duration, name, color);

    if (clip_id > 0) {
        win->selected_track = win->context_click_track;
        win->selected_clip_id = clip_id;
        printf("➕ Added clip at %.2fs on track %d\n", snap_time, win->context_click_track + 1);
    }

    gtk_popover_popdown(GTK_POPOVER(win->timeline_context_menu));
    gtk_widget_queue_draw(win->timeline_area);
}

static void on_context_delete_clip(GtkButton *button, gpointer user_data) {
    (void)button;
    MainWindow *win = (MainWindow *)user_data;
    if (!win || win->selected_clip_id == 0) return;

    if (track_remove_clip(win->audio_engine, win->selected_track, win->selected_clip_id)) {
        printf("🗑 Deleted clip from track %d\n", win->selected_track + 1);
        win->selected_clip_id = 0;
    }

    gtk_popover_popdown(GTK_POPOVER(win->timeline_context_menu));
    gtk_widget_queue_draw(win->timeline_area);
}

static void on_context_split_clip(GtkButton *button, gpointer user_data) {
    (void)button;
    MainWindow *win = (MainWindow *)user_data;
    if (!win || win->selected_clip_id == 0) return;

    // Split at the click position (not playhead)
    double split_time = win->context_click_time;

    // Verify click is inside the clip
    double start = track_get_clip_start(win->audio_engine, win->selected_track, win->selected_clip_id);
    double duration = track_get_clip_duration(win->audio_engine, win->selected_track, win->selected_clip_id);

    if (split_time > start && split_time < start + duration) {
        uint64_t new_id = track_split_clip(win->audio_engine, win->selected_track,
                                           win->selected_clip_id, split_time);
        if (new_id > 0) {
            printf("✂ Split clip at %.2fs\n", split_time);
        }
    }

    gtk_popover_popdown(GTK_POPOVER(win->timeline_context_menu));
    gtk_widget_queue_draw(win->timeline_area);
}

static void on_context_duplicate_clip(GtkButton *button, gpointer user_data) {
    (void)button;
    MainWindow *win = (MainWindow *)user_data;
    if (!win || win->selected_clip_id == 0) return;

    // Get original clip properties
    double start = track_get_clip_start(win->audio_engine, win->selected_track, win->selected_clip_id);
    double duration = track_get_clip_duration(win->audio_engine, win->selected_track, win->selected_clip_id);
    const char *name = track_get_clip_name(win->audio_engine, win->selected_track, win->selected_clip_id);
    uint32_t color = track_get_clip_color(win->audio_engine, win->selected_track, win->selected_clip_id);

    // Create duplicate right after the original
    double new_start = start + duration;

    char new_name[64];
    snprintf(new_name, sizeof(new_name), "%s (copy)", name);

    uint64_t new_id = track_add_clip(win->audio_engine, win->selected_track,
                                      new_start, duration, new_name, color);

    if (new_id > 0) {
        win->selected_clip_id = new_id;
        printf("📋 Duplicated clip to %.2fs\n", new_start);
    }

    gtk_popover_popdown(GTK_POPOVER(win->timeline_context_menu));
    gtk_widget_queue_draw(win->timeline_area);
}

static GtkWidget* create_context_menu_item(const char *icon, const char *label,
                                            GCallback callback, MainWindow *win) {
    GtkWidget *button = gtk_button_new();
    gtk_button_set_has_frame(GTK_BUTTON(button), FALSE);
    gtk_widget_add_css_class(button, "flat");

    GtkWidget *box = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8);
    gtk_widget_set_margin_start(box, 8);
    gtk_widget_set_margin_end(box, 8);
    gtk_widget_set_margin_top(box, 4);
    gtk_widget_set_margin_bottom(box, 4);

    if (icon) {
        GtkWidget *icon_label = gtk_label_new(icon);
        gtk_box_append(GTK_BOX(box), icon_label);
    }

    GtkWidget *text_label = gtk_label_new(label);
    gtk_widget_set_halign(text_label, GTK_ALIGN_START);
    gtk_widget_set_hexpand(text_label, TRUE);
    gtk_box_append(GTK_BOX(box), text_label);

    gtk_button_set_child(GTK_BUTTON(button), box);
    g_signal_connect(button, "clicked", callback, win);

    return button;
}

static void create_timeline_context_menu(MainWindow *win) {
    GtkWidget *popover = gtk_popover_new();
    gtk_popover_set_autohide(GTK_POPOVER(popover), TRUE);
    gtk_widget_set_parent(popover, win->timeline_area);

    GtkWidget *content = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0);
    gtk_widget_set_size_request(content, 160, -1);

    // Add Clip option (always available)
    gtk_box_append(GTK_BOX(content),
        create_context_menu_item("➕", "Add Clip", G_CALLBACK(on_context_add_clip), win));

    // Separator
    GtkWidget *sep = gtk_separator_new(GTK_ORIENTATION_HORIZONTAL);
    gtk_widget_set_margin_top(sep, 4);
    gtk_widget_set_margin_bottom(sep, 4);
    gtk_box_append(GTK_BOX(content), sep);

    // Clip-specific options
    gtk_box_append(GTK_BOX(content),
        create_context_menu_item("✂", "Split Clip", G_CALLBACK(on_context_split_clip), win));
    gtk_box_append(GTK_BOX(content),
        create_context_menu_item("📋", "Duplicate", G_CALLBACK(on_context_duplicate_clip), win));
    gtk_box_append(GTK_BOX(content),
        create_context_menu_item("🗑", "Delete", G_CALLBACK(on_context_delete_clip), win));

    gtk_popover_set_child(GTK_POPOVER(popover), content);
    win->timeline_context_menu = popover;
}

static void show_timeline_context_menu(MainWindow *win, double x, double y) {
    if (!win->timeline_context_menu) {
        create_timeline_context_menu(win);
    }

    // Position the popover at click location
    GdkRectangle rect = { (int)x, (int)y, 1, 1 };
    gtk_popover_set_pointing_to(GTK_POPOVER(win->timeline_context_menu), &rect);

    // Enable/disable clip-specific options based on selection
    GtkWidget *content = gtk_popover_get_child(GTK_POPOVER(win->timeline_context_menu));
    gboolean has_clip = (win->selected_clip_id > 0);

    // Find and update the split/duplicate/delete buttons (indices 2, 3, 4 after separator)
    GtkWidget *child = gtk_widget_get_first_child(content);
    int index = 0;
    while (child) {
        if (GTK_IS_BUTTON(child) && index >= 2) {
            gtk_widget_set_sensitive(child, has_clip);
        }
        child = gtk_widget_get_next_sibling(child);
        index++;
    }

    gtk_popover_popup(GTK_POPOVER(win->timeline_context_menu));
}

// =============================================================================
// Clip Dragging
// =============================================================================

static void on_timeline_drag_begin(GtkGestureDrag *gesture, double x, double y, gpointer user_data) {
    (void)gesture;
    MainWindow *win = (MainWindow *)user_data;
    if (!win || !win->viewport) return;

    win->dragging_clip = FALSE;
    win->dragging_midi_clip = FALSE;

    // Check if drag start is on a track
    int content_height = gtk_widget_get_height(win->timeline_area) - RULER_HEIGHT;
    int track_height = content_height / NUM_TRACKS;
    int drag_track = (int)((y - RULER_HEIGHT) / track_height);

    if (drag_track < 0 || drag_track >= NUM_TRACKS || x < TRACK_HEADER_WIDTH) {
        return;
    }

    double drag_time = timeline_viewport_x_to_seconds(win->viewport, x, TRACK_HEADER_WIDTH);
    const ViewportState *vp = timeline_viewport_get_state(win->viewport);

    // First check if dragging an audio clip
    if (win->selected_clip_id != 0 && drag_track == win->selected_track) {
        double clip_start = track_get_clip_start(win->audio_engine, win->selected_track, win->selected_clip_id);
        double clip_duration = track_get_clip_duration(win->audio_engine, win->selected_track, win->selected_clip_id);

        if (drag_time >= clip_start && drag_time < clip_start + clip_duration) {
            win->dragging_clip = TRUE;
            win->dragging_midi_clip = FALSE;
            win->drag_start_time = clip_start;
            win->drag_offset = drag_time - clip_start;
            printf("🎯 Started dragging audio clip\n");
            return;
        }
    }

    // Check if dragging a MIDI clip (instrument track)
    if (audio_engine_track_has_instrument(win->audio_engine, drag_track)) {
        double clip_start_beat = midi_clip_get_start_beat(drag_track);
        double clip_duration_beats = midi_clip_get_clip_duration(drag_track);
        double midi_clip_start = clip_start_beat * vp->seconds_per_beat;
        double midi_clip_end = midi_clip_start + (clip_duration_beats * vp->seconds_per_beat);

        if (drag_time >= midi_clip_start && drag_time < midi_clip_end) {
            win->dragging_clip = TRUE;
            win->dragging_midi_clip = TRUE;
            win->selected_track = drag_track;
            win->drag_start_time = midi_clip_start;
            win->drag_offset = drag_time - midi_clip_start;
            printf("🎹 Started dragging MIDI clip on track %d\n", drag_track + 1);
            return;
        }
    }
}

// Motion handler for cursor changes over trim handles
static void on_timeline_motion(GtkEventControllerMotion *controller, double x, double y, gpointer user_data) {
    (void)controller;
    (void)y;
    MainWindow *win = (MainWindow *)user_data;
    if (!win || !win->timeline_area) return;

    // Only show resize cursor when hovering over trim handles of selected clip
    if (win->selected_clip_id > 0 && win->selected_track >= 0) {
        int zone = get_clip_hit_zone(win, win->selected_track, win->selected_clip_id, x);
        if (zone == 1 || zone == 2) {
            // On trim handle - show horizontal resize cursor
            gtk_widget_set_cursor_from_name(win->timeline_area, "ew-resize");
            return;
        }
    }

    // Reset to default cursor
    gtk_widget_set_cursor(win->timeline_area, NULL);
}

static void on_timeline_drag_update(GtkGestureDrag *gesture, double offset_x, double offset_y, gpointer user_data) {
    (void)offset_y;
    MainWindow *win = (MainWindow *)user_data;
    if (!win) return;

    double start_x, start_y;
    gtk_gesture_drag_get_start_point(gesture, &start_x, &start_y);
    double current_x = start_x + offset_x;

    // Handle clip trimming
    if (win->is_trimming) {
        const ViewportState *vp = timeline_viewport_get_state(win->viewport);
        if (!vp) return;

        // Calculate time delta from mouse movement
        double start_time = timeline_viewport_x_to_seconds(win->viewport, win->trim_mouse_start_x, TRACK_HEADER_WIDTH);
        double current_time = timeline_viewport_x_to_seconds(win->viewport, current_x, TRACK_HEADER_WIDTH);
        double delta_time = current_time - start_time;

        // Snap delta to beat grid
        delta_time = round(delta_time / vp->seconds_per_beat) * vp->seconds_per_beat;

        if (win->trim_mode == 0) {
            // Trimming left edge
            double new_start = win->trim_start_time + delta_time;
            // Don't allow trimming past the end or before 0
            double max_start = win->trim_start_time + win->trim_start_duration - 0.1;
            if (new_start < 0) new_start = 0;
            if (new_start > max_start) new_start = max_start;
            track_trim_clip_start(win->audio_engine, win->selected_track, win->selected_clip_id, new_start);
        } else {
            // Trimming right edge
            double new_end = win->trim_start_time + win->trim_start_duration + delta_time;
            // Don't allow trimming before start
            double min_end = win->trim_start_time + 0.1;
            if (new_end < min_end) new_end = min_end;
            track_trim_clip_end(win->audio_engine, win->selected_track, win->selected_clip_id, new_end);
        }
        gtk_widget_queue_draw(win->timeline_area);
        return;
    }

    // Handle clip dragging
    if (!win->dragging_clip) return;

    double new_time = timeline_viewport_x_to_seconds(win->viewport, current_x, TRACK_HEADER_WIDTH);
    new_time -= win->drag_offset;

    // Snap to beat grid
    const ViewportState *vp = timeline_viewport_get_state(win->viewport);
    new_time = round(new_time / vp->seconds_per_beat) * vp->seconds_per_beat;

    if (new_time < 0) new_time = 0;

    // Update clip position in real-time
    if (win->dragging_midi_clip) {
        // Update MIDI clip position (in beats)
        double new_beat = new_time / vp->seconds_per_beat;
        midi_clip_set_start_beat(win->selected_track, new_beat);
    } else {
        // Update audio clip position
        track_set_clip_position(win->audio_engine, win->selected_track, win->selected_clip_id, new_time);
    }
    gtk_widget_queue_draw(win->timeline_area);
}

static void on_timeline_drag_end(GtkGestureDrag *gesture, double offset_x, double offset_y, gpointer user_data) {
    (void)gesture;
    (void)offset_x;
    (void)offset_y;
    MainWindow *win = (MainWindow *)user_data;
    if (!win) return;

    // Handle trim end
    if (win->is_trimming) {
        double new_start = track_get_clip_start(win->audio_engine, win->selected_track, win->selected_clip_id);
        double new_duration = track_get_clip_duration(win->audio_engine, win->selected_track, win->selected_clip_id);
        printf("✂️ Trimmed clip: start=%.2fs, duration=%.2fs\n", new_start, new_duration);
        win->is_trimming = FALSE;
        gtk_widget_queue_draw(win->timeline_area);
        return;
    }

    if (win->dragging_clip) {
        if (win->dragging_midi_clip) {
            double final_beat = midi_clip_get_start_beat(win->selected_track);
            printf("🎹 Moved MIDI clip to beat %.2f\n", final_beat);
        } else {
            double final_time = track_get_clip_start(win->audio_engine, win->selected_track, win->selected_clip_id);
            printf("📍 Moved audio clip to %.2fs\n", final_time);
        }
        win->dragging_clip = FALSE;
        win->dragging_midi_clip = FALSE;
    }
}

// Public API
MainWindow* main_window_new(GMainLoop *loop, void *audio_engine) {
    MainWindow *win = malloc(sizeof(MainWindow));
    if (!win) return NULL;

    // Initialize settings persistence (loads from disk if available)
    settings_init();

    // Initialize undo/redo system
    if (undo_init() != 0) {
        printf("Warning: Failed to initialize undo system\n");
    }

    // Initialize all fields
    // (Note: undo apply callback is set after memset below)
    memset(win, 0, sizeof(MainWindow));
    win->main_loop = loop;
    win->audio_engine = audio_engine;

    // Load BPM and time signature from persisted settings
    win->bpm = settings_get_default_bpm();
    win->time_sig_numerator = (int)settings_get_default_time_sig_num();
    win->time_sig_denominator = (int)settings_get_default_time_sig_den();

    // Default gain values
    for (int i = 0; i < NUM_TRACKS; i++) {
        win->track_gains[i] = 0.75f;
        win->track_colors[i] = 0;  // Will use defaults
    }
    win->master_gain = 0.75f;

    // Initialize selection state
    win->selected_track = -1;
    win->selected_clip_id = 0;

    // Initialize context menu state
    win->timeline_context_menu = NULL;
    win->context_click_time = 0.0;
    win->context_click_track = 0;

    // Initialize dragging state
    win->dragging_clip = FALSE;
    win->dragging_midi_clip = FALSE;
    win->drag_start_time = 0.0;
    win->drag_offset = 0.0;

    // Initialize recording state
    win->recording = FALSE;
    win->recording_track = 0;
    win->recording_start = 0.0;

    // Create timeline viewport
    win->viewport = timeline_viewport_new();
    if (!win->viewport) {
        free(win);
        return NULL;
    }

    // Create window
    win->window = gtk_window_new();
    gtk_window_set_title(GTK_WINDOW(win->window), "DAW v0.1.0");
    // Default size fits 13" MacBook (1440x900 or 1280x800 scaled)
    gtk_window_set_default_size(GTK_WINDOW(win->window), 1100, 700);

    // Set minimum size for usability
    GdkContentProvider *provider = NULL;
    (void)provider; // Suppress unused warning
    gtk_widget_set_size_request(win->window, 900, 550);

    // Enable fullscreen support
    gtk_window_set_resizable(GTK_WINDOW(win->window), TRUE);

    // Connect event handlers
    g_signal_connect(win->window, "destroy", G_CALLBACK(on_window_destroy), win);
    g_signal_connect(win->window, "notify::fullscreened", G_CALLBACK(on_window_state_changed), win);
    g_signal_connect(win->window, "notify::maximized", G_CALLBACK(on_window_state_changed), win);
    g_signal_connect(win->window, "realize", G_CALLBACK(on_window_realize), win);

    // Main container
    win->main_box = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0);

    // Transport bar (replaces header bar) - Tokyo Night background
    win->transport_bar = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 12);
    gtk_widget_set_margin_start(win->transport_bar, 12);
    gtk_widget_set_margin_end(win->transport_bar, 12);
    gtk_widget_set_margin_top(win->transport_bar, 8);
    gtk_widget_set_margin_bottom(win->transport_bar, 8);

    // Session menu (modern dropdown replacing individual file buttons)
    DawSessionMenuCallbacks session_callbacks = {
        .on_new = session_on_new,
        .on_open = session_on_open,
        .on_save = session_on_save,
        .on_save_as = session_on_save_as,
        .on_export_audio = session_on_export_audio,
        .on_export_midi = session_on_export_midi,
        .on_import = session_on_import,
        .user_data = win
    };
    GtkWidget *session_menu = daw_session_menu_new(&session_callbacks);
    gtk_box_append(GTK_BOX(win->transport_bar), session_menu);

    // Separator between file and edit
    GtkWidget *edit_sep = gtk_separator_new(GTK_ORIENTATION_VERTICAL);
    gtk_box_append(GTK_BOX(win->transport_bar), edit_sep);

    // Edit buttons (Undo/Redo) - icon-only
    GtkWidget *edit_box = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 4);

    GtkWidget *undo_button = daw_transport_button("↩", "Undo (Cmd+Z)", NULL);
    g_signal_connect(undo_button, "clicked", G_CALLBACK(on_undo_clicked), win);

    GtkWidget *redo_button = daw_transport_button("↪", "Redo (Cmd+Shift+Z)", NULL);
    g_signal_connect(redo_button, "clicked", G_CALLBACK(on_redo_clicked), win);

    gtk_box_append(GTK_BOX(edit_box), undo_button);
    gtk_box_append(GTK_BOX(edit_box), redo_button);
    gtk_box_append(GTK_BOX(win->transport_bar), edit_box);

    // Separator between edit and transport
    GtkWidget *file_sep = gtk_separator_new(GTK_ORIENTATION_VERTICAL);
    gtk_box_append(GTK_BOX(win->transport_bar), file_sep);

    // Transport controls - minimal icon-only buttons
    GtkWidget *transport_box = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 4);

    win->play_button = daw_transport_button("▶", "Play/Pause", DAW_COLOR_GREEN);
    win->stop_button = daw_transport_button("⏹", "Stop", DAW_COLOR_FG);
    win->record_button = daw_transport_button("⏺", "Record", DAW_COLOR_RED);

    g_signal_connect(win->play_button, "clicked", G_CALLBACK(on_play_clicked), win);
    g_signal_connect(win->stop_button, "clicked", G_CALLBACK(on_stop_clicked), win);
    g_signal_connect(win->record_button, "clicked", G_CALLBACK(on_record_clicked), win);

    gtk_box_append(GTK_BOX(transport_box), win->play_button);
    gtk_box_append(GTK_BOX(transport_box), win->stop_button);
    gtk_box_append(GTK_BOX(transport_box), win->record_button);

    gtk_box_append(GTK_BOX(win->transport_bar), transport_box);

    // Position label
    win->position_label = gtk_label_new("00:00.000");
    gtk_widget_set_margin_start(win->position_label, 12);
    gtk_widget_set_margin_end(win->position_label, 12);
    gtk_box_append(GTK_BOX(win->transport_bar), win->position_label);

    // BPM control
    GtkWidget *bpm_box = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 4);
    GtkWidget *bpm_label = gtk_label_new("♩ BPM:");
    win->bpm_spin = gtk_spin_button_new_with_range(40.0, 300.0, 1.0);
    gtk_spin_button_set_value(GTK_SPIN_BUTTON(win->bpm_spin), 120.0);
    gtk_spin_button_set_digits(GTK_SPIN_BUTTON(win->bpm_spin), 0);
    gtk_widget_set_size_request(win->bpm_spin, 70, -1);
    g_signal_connect(win->bpm_spin, "value-changed", G_CALLBACK(on_bpm_changed), win);

    gtk_box_append(GTK_BOX(bpm_box), bpm_label);
    gtk_box_append(GTK_BOX(bpm_box), win->bpm_spin);

    gtk_box_append(GTK_BOX(win->transport_bar), bpm_box);

    // Time signature control
    GtkWidget *time_sig_box = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 4);
    GtkWidget *time_sig_label = gtk_label_new("Time:");
    win->time_sig_num = gtk_spin_button_new_with_range(1.0, 16.0, 1.0);
    gtk_spin_button_set_value(GTK_SPIN_BUTTON(win->time_sig_num), 4.0);
    gtk_spin_button_set_digits(GTK_SPIN_BUTTON(win->time_sig_num), 0);
    gtk_widget_set_size_request(win->time_sig_num, 50, -1);
    g_signal_connect(win->time_sig_num, "value-changed", G_CALLBACK(on_time_sig_changed), win);

    GtkWidget *slash_label = gtk_label_new("/");

    win->time_sig_den = gtk_spin_button_new_with_range(1.0, 16.0, 1.0);
    gtk_spin_button_set_value(GTK_SPIN_BUTTON(win->time_sig_den), 4.0);
    gtk_spin_button_set_digits(GTK_SPIN_BUTTON(win->time_sig_den), 0);
    gtk_widget_set_size_request(win->time_sig_den, 50, -1);
    g_signal_connect(win->time_sig_den, "value-changed", G_CALLBACK(on_time_sig_changed), win);

    gtk_box_append(GTK_BOX(time_sig_box), time_sig_label);
    gtk_box_append(GTK_BOX(time_sig_box), win->time_sig_num);
    gtk_box_append(GTK_BOX(time_sig_box), slash_label);
    gtk_box_append(GTK_BOX(time_sig_box), win->time_sig_den);

    gtk_box_append(GTK_BOX(win->transport_bar), time_sig_box);

    // Spacer to push settings button to the right
    GtkWidget *spacer = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 0);
    gtk_widget_set_hexpand(spacer, TRUE);
    gtk_box_append(GTK_BOX(win->transport_bar), spacer);

    // Settings button
    GtkWidget *settings_button = gtk_button_new_with_label("⚙");
    gtk_widget_set_tooltip_text(settings_button, "Settings");
    g_signal_connect(settings_button, "clicked", G_CALLBACK(on_settings_clicked), win);
    gtk_box_append(GTK_BOX(win->transport_bar), settings_button);

    // Add transport bar to main box
    gtk_box_append(GTK_BOX(win->main_box), win->transport_bar);

    // Create horizontal layout for content area (timeline + library panel)
    GtkWidget *content_box = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 0);
    gtk_widget_set_vexpand(content_box, TRUE);

    // Timeline area (left side, expands)
    GtkWidget *timeline_frame = gtk_frame_new("Timeline");
    gtk_widget_set_vexpand(timeline_frame, TRUE);
    gtk_widget_set_hexpand(timeline_frame, TRUE);

    win->timeline_area = gtk_drawing_area_new();
    gtk_widget_set_vexpand(win->timeline_area, TRUE);
    gtk_drawing_area_set_draw_func(
        GTK_DRAWING_AREA(win->timeline_area),
        (GtkDrawingAreaDrawFunc)draw_timeline,
        win,
        NULL
    );

    // Add click gesture to timeline for seeking/selection (responds to all buttons for context menu)
    GtkGesture *click_gesture = gtk_gesture_click_new();
    gtk_gesture_single_set_button(GTK_GESTURE_SINGLE(click_gesture), 0);  // 0 = any button
    g_signal_connect(click_gesture, "pressed", G_CALLBACK(on_timeline_click), win);
    gtk_widget_add_controller(win->timeline_area, GTK_EVENT_CONTROLLER(click_gesture));

    // Add drag gesture to timeline for clip dragging
    GtkGesture *drag_gesture = gtk_gesture_drag_new();
    gtk_gesture_single_set_button(GTK_GESTURE_SINGLE(drag_gesture), GDK_BUTTON_PRIMARY);
    g_signal_connect(drag_gesture, "drag-begin", G_CALLBACK(on_timeline_drag_begin), win);
    g_signal_connect(drag_gesture, "drag-update", G_CALLBACK(on_timeline_drag_update), win);
    g_signal_connect(drag_gesture, "drag-end", G_CALLBACK(on_timeline_drag_end), win);
    gtk_widget_add_controller(win->timeline_area, GTK_EVENT_CONTROLLER(drag_gesture));

    // Add motion controller for cursor changes over trim handles
    GtkEventController *motion_controller = gtk_event_controller_motion_new();
    g_signal_connect(motion_controller, "motion", G_CALLBACK(on_timeline_motion), win);
    gtk_widget_add_controller(win->timeline_area, motion_controller);

    // Add scroll controller for zoom/pan
    GtkEventController *scroll_controller = gtk_event_controller_scroll_new(
        GTK_EVENT_CONTROLLER_SCROLL_BOTH_AXES);
    g_signal_connect(scroll_controller, "scroll", G_CALLBACK(on_timeline_scroll), win);
    gtk_widget_add_controller(win->timeline_area, scroll_controller);

    // Add keyboard controller for shortcuts
    GtkEventController *key_controller = gtk_event_controller_key_new();
    g_signal_connect(key_controller, "key-pressed", G_CALLBACK(on_timeline_key), win);
    gtk_widget_add_controller(win->timeline_area, key_controller);

    // Make timeline focusable for keyboard events
    gtk_widget_set_focusable(win->timeline_area, TRUE);
    gtk_widget_set_can_focus(win->timeline_area, TRUE);

    // Note: Native GtkDropTarget causes crash on macOS (GdkMacosPasteboardItem bug)
    // Instead, we use custom GtkGestureDrag in library_panel_gtk.c
    // The drag gesture callback calculates track from cursor position

    gtk_frame_set_child(GTK_FRAME(timeline_frame), win->timeline_area);
    gtk_box_append(GTK_BOX(content_box), timeline_frame);

    // Library panel (right side, fixed width)
    GtkWidget *library_separator = gtk_separator_new(GTK_ORIENTATION_VERTICAL);
    gtk_box_append(GTK_BOX(content_box), library_separator);

    win->library_panel = library_panel_new(audio_engine);
    if (win->library_panel) {
        // Set callback for when library items are clicked
        library_panel_set_drop_callback(win->library_panel, on_library_item_selected, win);

        GtkWidget *library_widget = library_panel_get_widget(win->library_panel);
        gtk_box_append(GTK_BOX(content_box), library_widget);
    }

    gtk_box_append(GTK_BOX(win->main_box), content_box);

    // Logic Pro-style compact mixer - combined fader+meter widgets
    // Fixed height, does not expand, clean horizontal layout
    GtkWidget *mixer_frame = gtk_frame_new(NULL);
    gtk_widget_set_margin_start(mixer_frame, 8);
    gtk_widget_set_margin_end(mixer_frame, 8);
    gtk_widget_set_margin_top(mixer_frame, 2);
    gtk_widget_set_margin_bottom(mixer_frame, 4);

    win->mixer_box = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 6);
    gtk_widget_set_margin_start(win->mixer_box, 8);
    gtk_widget_set_margin_end(win->mixer_box, 8);
    gtk_widget_set_margin_top(win->mixer_box, 6);
    gtk_widget_set_margin_bottom(win->mixer_box, 6);

    // Track channels - compact inline strips with combined fader+meter
    // CSS for ultra-compact buttons
    GtkCssProvider *btn_css = gtk_css_provider_new();
    gtk_css_provider_load_from_string(btn_css,
        ".compact-btn { min-width: 0; min-height: 0; padding: 1px 3px; font-size: 9px; }");

    for (int i = 0; i < 4; i++) {
        GtkWidget *track_strip = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 1);

        // Track number (minimal)
        char track_name[8];
        snprintf(track_name, sizeof(track_name), "%d", i + 1);
        GtkWidget *label = gtk_label_new(track_name);
        gtk_widget_set_size_request(label, 12, -1);
        gtk_box_append(GTK_BOX(track_strip), label);

        // Mute/Solo/Arm/Instrument/FX buttons (ultra compact)
        GtkWidget *mute_btn = gtk_button_new_with_label("M");
        GtkWidget *solo_btn = gtk_button_new_with_label("S");
        GtkWidget *arm_btn = gtk_button_new_with_label("R");
        GtkWidget *inst_btn = gtk_button_new_with_label("I");
        GtkWidget *fx_btn = gtk_button_new_with_label("FX");

        // Apply compact CSS class
        gtk_widget_add_css_class(mute_btn, "compact-btn");
        gtk_widget_add_css_class(solo_btn, "compact-btn");
        gtk_widget_add_css_class(arm_btn, "compact-btn");
        gtk_widget_add_css_class(inst_btn, "compact-btn");
        gtk_widget_add_css_class(fx_btn, "compact-btn");
        gtk_style_context_add_provider(gtk_widget_get_style_context(mute_btn), GTK_STYLE_PROVIDER(btn_css), GTK_STYLE_PROVIDER_PRIORITY_APPLICATION);
        gtk_style_context_add_provider(gtk_widget_get_style_context(solo_btn), GTK_STYLE_PROVIDER(btn_css), GTK_STYLE_PROVIDER_PRIORITY_APPLICATION);
        gtk_style_context_add_provider(gtk_widget_get_style_context(arm_btn), GTK_STYLE_PROVIDER(btn_css), GTK_STYLE_PROVIDER_PRIORITY_APPLICATION);
        gtk_style_context_add_provider(gtk_widget_get_style_context(inst_btn), GTK_STYLE_PROVIDER(btn_css), GTK_STYLE_PROVIDER_PRIORITY_APPLICATION);
        gtk_style_context_add_provider(gtk_widget_get_style_context(fx_btn), GTK_STYLE_PROVIDER(btn_css), GTK_STYLE_PROVIDER_PRIORITY_APPLICATION);

        gtk_widget_set_tooltip_text(inst_btn, "Open Instrument (I)");
        gtk_widget_set_tooltip_text(fx_btn, "Open Effects Chain (E)");
        g_object_set_data(G_OBJECT(mute_btn), "track-index", GINT_TO_POINTER(i));
        g_object_set_data(G_OBJECT(solo_btn), "track-index", GINT_TO_POINTER(i));
        g_object_set_data(G_OBJECT(arm_btn), "track-index", GINT_TO_POINTER(i));
        g_object_set_data(G_OBJECT(inst_btn), "track-index", GINT_TO_POINTER(i));
        g_object_set_data(G_OBJECT(fx_btn), "track-index", GINT_TO_POINTER(i));
        g_signal_connect(mute_btn, "clicked", G_CALLBACK(on_mute_clicked), win);
        g_signal_connect(solo_btn, "clicked", G_CALLBACK(on_solo_clicked), win);
        g_signal_connect(arm_btn, "clicked", G_CALLBACK(on_arm_clicked), win);
        g_signal_connect(inst_btn, "clicked", G_CALLBACK(on_instrument_clicked), win);
        g_signal_connect(fx_btn, "clicked", G_CALLBACK(on_effects_clicked), win);
        gtk_box_append(GTK_BOX(track_strip), mute_btn);
        gtk_box_append(GTK_BOX(track_strip), solo_btn);
        gtk_box_append(GTK_BOX(track_strip), arm_btn);
        gtk_box_append(GTK_BOX(track_strip), inst_btn);
        gtk_box_append(GTK_BOX(track_strip), fx_btn);

        // Pan knob (RX-style circular knob)
        GtkWidget *pan_knob = gtk_drawing_area_new();
        win->track_pan_knobs[i] = pan_knob;
        gtk_widget_set_size_request(pan_knob, 22, 22);
        gtk_widget_set_tooltip_text(pan_knob, "Pan (drag left/right)");
        gtk_drawing_area_set_draw_func(
            GTK_DRAWING_AREA(pan_knob),
            (GtkDrawingAreaDrawFunc)draw_pan_knob,
            win,
            NULL
        );

        // Add drag gesture for pan control
        GtkGesture *pan_drag = gtk_gesture_drag_new();
        g_signal_connect(pan_drag, "drag-begin", G_CALLBACK(on_pan_drag), win);
        g_signal_connect(pan_drag, "drag-update", G_CALLBACK(on_pan_drag_update), win);
        gtk_widget_add_controller(pan_knob, GTK_EVENT_CONTROLLER(pan_drag));
        gtk_box_append(GTK_BOX(track_strip), pan_knob);

        // Add drop target for drag-and-drop from library
        GtkDropTarget *drop_target = gtk_drop_target_new(G_TYPE_STRING, GDK_ACTION_COPY);
        g_object_set_data(G_OBJECT(drop_target), "track-index", GINT_TO_POINTER(i));
        g_signal_connect(drop_target, "drop", G_CALLBACK(on_track_drop), win);
        g_signal_connect(drop_target, "enter", G_CALLBACK(on_track_drop_enter), win);
        g_signal_connect(drop_target, "leave", G_CALLBACK(on_track_drop_leave), win);
        gtk_widget_add_controller(track_strip, GTK_EVENT_CONTROLLER(drop_target));
        win->track_drop_zones[i] = track_strip;

        // Combined fader+meter widget (Logic Pro style - meter inside fader trough)
        GtkWidget *fader_meter = gtk_drawing_area_new();
        win->track_fader_meters[i] = fader_meter;
        gtk_widget_set_size_request(fader_meter, 100, 18);
        gtk_drawing_area_set_draw_func(
            GTK_DRAWING_AREA(fader_meter),
            (GtkDrawingAreaDrawFunc)draw_fader_meter,
            win,
            NULL
        );

        // Add drag gesture for fader control
        GtkGesture *drag = gtk_gesture_drag_new();
        g_signal_connect(drag, "drag-begin", G_CALLBACK(on_fader_drag), win);
        g_signal_connect(drag, "drag-update", G_CALLBACK(on_fader_drag_update), win);
        gtk_widget_add_controller(fader_meter, GTK_EVENT_CONTROLLER(drag));

        gtk_box_append(GTK_BOX(track_strip), fader_meter);
        gtk_box_append(GTK_BOX(win->mixer_box), track_strip);

        // Separator between tracks (subtle)
        if (i < 3) {
            GtkWidget *sep = gtk_separator_new(GTK_ORIENTATION_VERTICAL);
            gtk_widget_set_margin_start(sep, 2);
            gtk_widget_set_margin_end(sep, 2);
            gtk_box_append(GTK_BOX(win->mixer_box), sep);
        }
    }

    // Master separator (more prominent)
    GtkWidget *master_sep = gtk_separator_new(GTK_ORIENTATION_VERTICAL);
    gtk_widget_set_margin_start(master_sep, 6);
    gtk_widget_set_margin_end(master_sep, 6);
    gtk_box_append(GTK_BOX(win->mixer_box), master_sep);

    // Master channel strip with combined fader+meter
    GtkWidget *master_strip = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 2);

    GtkWidget *master_label = gtk_label_new(NULL);
    gtk_label_set_markup(GTK_LABEL(master_label), "<b>M</b>");
    gtk_widget_set_size_request(master_label, 14, -1);
    gtk_box_append(GTK_BOX(master_strip), master_label);

    // Master FX button
    GtkWidget *master_fx_btn = gtk_button_new_with_label("FX");
    gtk_widget_add_css_class(master_fx_btn, "compact-btn");
    gtk_style_context_add_provider(gtk_widget_get_style_context(master_fx_btn), GTK_STYLE_PROVIDER(btn_css), GTK_STYLE_PROVIDER_PRIORITY_APPLICATION);
    gtk_widget_set_tooltip_text(master_fx_btn, "Master Effects (Shift+E)");
    g_signal_connect(master_fx_btn, "clicked", G_CALLBACK(on_master_effects_clicked), win);
    gtk_box_append(GTK_BOX(master_strip), master_fx_btn);

    // Master combined fader+meter (stereo, Logic Pro style)
    win->master_fader_meter = gtk_drawing_area_new();
    gtk_widget_set_size_request(win->master_fader_meter, 120, 18);
    gtk_drawing_area_set_draw_func(
        GTK_DRAWING_AREA(win->master_fader_meter),
        (GtkDrawingAreaDrawFunc)draw_master_fader_meter,
        win,
        NULL
    );

    // Add drag gesture for master fader
    GtkGesture *master_drag = gtk_gesture_drag_new();
    g_signal_connect(master_drag, "drag-begin", G_CALLBACK(on_fader_drag), win);
    g_signal_connect(master_drag, "drag-update", G_CALLBACK(on_fader_drag_update), win);
    gtk_widget_add_controller(win->master_fader_meter, GTK_EVENT_CONTROLLER(master_drag));

    gtk_box_append(GTK_BOX(master_strip), win->master_fader_meter);
    gtk_box_append(GTK_BOX(win->mixer_box), master_strip);

    gtk_frame_set_child(GTK_FRAME(mixer_frame), win->mixer_box);
    gtk_box_append(GTK_BOX(win->main_box), mixer_frame);

    // Piano roll (hidden by default, shown on double-click or P key)
    win->piano_roll = piano_roll_new(win->audio_engine);
    if (win->piano_roll) {
        GtkWidget *piano_roll_widget = piano_roll_get_widget(win->piano_roll);
        if (piano_roll_widget) {
            gtk_box_append(GTK_BOX(win->main_box), piano_roll_widget);
        }
    }

    // Status bar
    win->status_label = gtk_label_new("♩ 120 BPM | 4/4");
    gtk_widget_set_halign(win->status_label, GTK_ALIGN_START);
    gtk_widget_set_margin_start(win->status_label, 12);
    gtk_widget_set_margin_end(win->status_label, 12);
    gtk_widget_set_margin_top(win->status_label, 6);
    gtk_widget_set_margin_bottom(win->status_label, 6);

    GtkWidget *status_bar = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 0);
    gtk_box_append(GTK_BOX(status_bar), win->status_label);
    gtk_widget_add_css_class(status_bar, "statusbar");

    gtk_box_append(GTK_BOX(win->main_box), status_bar);

    gtk_window_set_child(GTK_WINDOW(win->window), win->main_box);

    // Start update timer (100ms interval)
    win->timer_id = g_timeout_add(100, update_playback, win);

    // Set up undo system callback
    g_main_window_for_undo = win;
    undo_set_apply_callback(undo_apply_action);

    // Set default instrument (Keys) on track 1 so MIDI playback works immediately
    if (audio_engine_set_track_instrument(win->audio_engine, 0, 0) == 0) {  // 0 = Keys
        printf("🎹 Added default Keys instrument to Track 1\n");
        // Add demo MIDI notes so there's something to play
        midi_clip_add_demo_notes(0);
        printf("🎵 Added demo MIDI notes to Track 1 (C-G-Am-F chord progression)\n");
    }

    printf("✅ DAW window initialized\n");
    printf("   - 4 tracks ready (Track 1 has Keys instrument)\n");
    printf("   - Master bus configured\n");
    printf("   - Transport controls active\n");
    printf("   - Undo/Redo system ready\n");
    printf("   - Double-click track to open Piano Roll\n");
    printf("   - Press P to open Piano Roll for selected track\n");

    return win;
}

void main_window_show(MainWindow *win) {
    if (!win) return;
    gtk_window_present(GTK_WINDOW(win->window));
}

void main_window_destroy(MainWindow *win) {
    if (!win) return;
    gtk_window_destroy(GTK_WINDOW(win->window));
    free(win);
}

void main_window_update_transport(MainWindow *win, gboolean playing, gdouble position) {
    if (!win) return;

    win->playing = playing;
    win->position = position;

    // Update position label
    int minutes = (int)(position / 60.0);
    double seconds = position - (minutes * 60.0);
    char pos_text[32];
    snprintf(pos_text, sizeof(pos_text), "%02d:%06.3f", minutes, seconds);
    gtk_label_set_text(GTK_LABEL(win->position_label), pos_text);
}

void main_window_update_meters(MainWindow *win, const float *levels, int count) {
    if (!win || !levels) return;
    (void)count;
    // Stub for now
}

void main_window_set_status(MainWindow *win, const char *message) {
    if (!win || !message) return;
    gtk_label_set_text(GTK_LABEL(win->status_label), message);
}
