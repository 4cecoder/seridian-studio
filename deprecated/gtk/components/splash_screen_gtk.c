/**
 * DAW Splash Screen Implementation
 *
 * A visually striking loading screen with:
 * - Centered logo/title with glow effect
 * - Animated progress bar with shimmer
 * - Floating particle effects
 * - Smooth stage transitions
 * - Tokyo Night color scheme
 */

#include "splash_screen_gtk.h"
#include "daw_widgets.h"
#include <math.h>
#include <stdlib.h>
#include <string.h>

// Portable M_PI definition
#ifndef M_PI
#define M_PI 3.14159265358979323846
#endif

// Stage descriptions
static const char* stage_messages[] = {
    "Starting up...",
    "Loading configuration...",
    "Initializing audio engine...",
    "Connecting audio backend...",
    "Initializing MIDI...",
    "Loading project system...",
    "Loading theme...",
    "Creating main window...",
    "Ready!"
};

// Stage progress percentages (0.0 - 1.0)
static const float stage_progress[] = {
    0.00f,  // INIT
    0.10f,  // CONFIG
    0.25f,  // AUDIO_ENGINE
    0.40f,  // AUDIO_BACKEND
    0.55f,  // MIDI
    0.70f,  // PROJECT
    0.80f,  // UI_THEME
    0.90f,  // UI_WINDOW
    1.00f   // COMPLETE
};

// Particle system for visual effect
#define MAX_PARTICLES 30

typedef struct {
    double x, y;
    double vx, vy;
    double size;
    double alpha;
    double hue;  // 0=blue, 1=purple
} Particle;

struct SplashScreen {
    GtkWidget *window;
    GtkWidget *drawing_area;

    float current_progress;    // Animated progress value
    float target_progress;     // Target progress value
    SplashStage current_stage;
    char detail_text[256];     // Detail message drawn in Cairo

    guint animation_timer;
    gint64 start_time;

    gboolean closing;
    float fade_alpha;

    // Particle system
    Particle particles[MAX_PARTICLES];
    int particle_count;
};

// Forward declarations
static void draw_splash(GtkDrawingArea *area, cairo_t *cr, int width, int height, gpointer user_data);
static gboolean animate_progress(gpointer user_data);
static void init_particles(SplashScreen *splash);
static void update_particles(SplashScreen *splash, double dt);

static void init_particles(SplashScreen *splash) {
    splash->particle_count = MAX_PARTICLES;
    for (int i = 0; i < MAX_PARTICLES; i++) {
        Particle *p = &splash->particles[i];
        p->x = (double)(rand() % 480);
        p->y = (double)(rand() % 320);
        p->vx = ((double)(rand() % 100) - 50) / 100.0;
        p->vy = -0.2 - ((double)(rand() % 50)) / 100.0;  // Drift upward
        p->size = 1.0 + ((double)(rand() % 30)) / 10.0;
        p->alpha = 0.1 + ((double)(rand() % 40)) / 100.0;
        p->hue = ((double)(rand() % 100)) / 100.0;
    }
}

static void update_particles(SplashScreen *splash, double dt) {
    for (int i = 0; i < splash->particle_count; i++) {
        Particle *p = &splash->particles[i];
        p->x += p->vx * dt * 60.0;
        p->y += p->vy * dt * 60.0;

        // Wrap around
        if (p->y < -10) {
            p->y = 330;
            p->x = (double)(rand() % 480);
        }
        if (p->x < -10) p->x = 490;
        if (p->x > 490) p->x = -10;
    }
}

// Create glow effect color stops
static void set_glow_gradient(cairo_t *cr, double cx, double cy, double radius) {
    cairo_pattern_t *gradient = cairo_pattern_create_radial(cx, cy, 0, cx, cy, radius);
    cairo_pattern_add_color_stop_rgba(gradient, 0.0, 0.48, 0.64, 0.97, 0.25);  // Blue center
    cairo_pattern_add_color_stop_rgba(gradient, 0.4, 0.48, 0.64, 0.97, 0.08);
    cairo_pattern_add_color_stop_rgba(gradient, 1.0, 0.48, 0.64, 0.97, 0.0);   // Transparent edge
    cairo_set_source(cr, gradient);
    cairo_pattern_destroy(gradient);
}

static void draw_splash(GtkDrawingArea *area, cairo_t *cr, int width, int height, gpointer user_data) {
    (void)area;
    SplashScreen *splash = (SplashScreen*)user_data;

    double w = width;
    double h = height;
    double cx = w / 2.0;
    double cy = h / 2.0;

    // Background - dark with subtle gradient
    cairo_pattern_t *bg = cairo_pattern_create_linear(0, 0, 0, h);
    cairo_pattern_add_color_stop_rgb(bg, 0.0, 0.05, 0.05, 0.08);   // Darker top
    cairo_pattern_add_color_stop_rgb(bg, 0.5, 0.08, 0.08, 0.12);   // Mid
    cairo_pattern_add_color_stop_rgb(bg, 1.0, 0.06, 0.06, 0.10);   // Darker bottom
    cairo_set_source(cr, bg);
    cairo_paint(cr);
    cairo_pattern_destroy(bg);

    // Calculate animation time
    gint64 now = g_get_monotonic_time();
    double elapsed = (now - splash->start_time) / 1000000.0;

    // Apply fade if closing
    if (splash->closing) {
        cairo_push_group(cr);
    }

    // Draw floating particles (behind everything)
    for (int i = 0; i < splash->particle_count; i++) {
        Particle *p = &splash->particles[i];

        // Interpolate between blue and purple based on hue
        double r = 0.48 + 0.25 * p->hue;  // Blue to purple
        double g = 0.64 - 0.04 * p->hue;
        double b = 0.97;

        // Pulse alpha slightly
        double alpha_mod = 0.8 + 0.2 * sin(elapsed * 2.0 + i * 0.5);
        cairo_set_source_rgba(cr, r, g, b, p->alpha * alpha_mod);
        cairo_arc(cr, p->x, p->y, p->size, 0, 2 * M_PI);
        cairo_fill(cr);
    }

    // Central glow effect
    set_glow_gradient(cr, cx, cy - 50, 180);
    cairo_arc(cr, cx, cy - 50, 180, 0, 2 * M_PI);
    cairo_fill(cr);

    // Secondary glow (purple tint, offset)
    cairo_pattern_t *glow2 = cairo_pattern_create_radial(cx + 60, cy - 30, 0, cx + 60, cy - 30, 120);
    cairo_pattern_add_color_stop_rgba(glow2, 0.0, 0.73, 0.60, 0.97, 0.15);  // Purple
    cairo_pattern_add_color_stop_rgba(glow2, 1.0, 0.73, 0.60, 0.97, 0.0);
    cairo_set_source(cr, glow2);
    cairo_arc(cr, cx + 60, cy - 30, 120, 0, 2 * M_PI);
    cairo_fill(cr);
    cairo_pattern_destroy(glow2);

    // Pulse effect
    double pulse = 0.5 + 0.5 * sin(elapsed * 2.5);

    // Logo text with glow effect
    cairo_select_font_face(cr, "SF Pro Display, Inter, system-ui",
                           CAIRO_FONT_SLANT_NORMAL, CAIRO_FONT_WEIGHT_BOLD);
    cairo_set_font_size(cr, 64);

    cairo_text_extents_t extents;
    cairo_text_extents(cr, "ByteCats DAW", &extents);
    double text_x = cx - extents.width / 2.0;
    double text_y = cy - 35;

    // Text glow layers (creates blur effect)
    for (int i = 5; i >= 1; i--) {
        double spread = i * 2.0;
        double alpha = 0.08 * (1.0 - i / 6.0) * (0.7 + 0.3 * pulse);
        cairo_set_source_rgba(cr, 0.48, 0.64, 0.97, alpha);

        for (int dx = -1; dx <= 1; dx++) {
            for (int dy = -1; dy <= 1; dy++) {
                cairo_move_to(cr, text_x + dx * spread, text_y + dy * spread);
                cairo_show_text(cr, "ByteCats DAW");
            }
        }
    }

    // Main text
    cairo_set_source_rgb(cr, 0.80, 0.84, 0.98);
    cairo_move_to(cr, text_x, text_y);
    cairo_show_text(cr, "ByteCats DAW");

    // Subtitle
    cairo_set_font_size(cr, 13);
    cairo_text_extents(cr, "Digital Audio Workstation", &extents);
    cairo_set_source_rgba(cr, 0.66, 0.69, 0.84, 0.7);
    cairo_move_to(cr, cx - extents.width / 2.0, text_y + 28);
    cairo_show_text(cr, "Digital Audio Workstation");

    // Progress bar dimensions
    double bar_width = 280;
    double bar_height = 4;
    double bar_x = cx - bar_width / 2.0;
    double bar_y = cy + 55;
    double bar_radius = bar_height / 2.0;

    // Bar track (subtle)
    cairo_set_source_rgba(cr, 0.16, 0.18, 0.26, 0.8);
    cairo_new_path(cr);
    cairo_arc(cr, bar_x + bar_radius, bar_y + bar_radius, bar_radius, M_PI / 2, 3 * M_PI / 2);
    cairo_arc(cr, bar_x + bar_width - bar_radius, bar_y + bar_radius, bar_radius, 3 * M_PI / 2, M_PI / 2);
    cairo_close_path(cr);
    cairo_fill(cr);

    // Progress fill
    if (splash->current_progress > 0.005) {
        double fill_width = bar_width * splash->current_progress;
        if (fill_width < bar_height) fill_width = bar_height;

        // Gradient from purple to blue
        cairo_pattern_t *progress_grad = cairo_pattern_create_linear(bar_x, 0, bar_x + bar_width, 0);
        cairo_pattern_add_color_stop_rgb(progress_grad, 0.0, 0.73, 0.60, 0.97);  // Purple
        cairo_pattern_add_color_stop_rgb(progress_grad, 0.5, 0.60, 0.62, 0.97);  // Mid
        cairo_pattern_add_color_stop_rgb(progress_grad, 1.0, 0.48, 0.64, 0.97);  // Blue
        cairo_set_source(cr, progress_grad);

        cairo_new_path(cr);
        cairo_arc(cr, bar_x + bar_radius, bar_y + bar_radius, bar_radius, M_PI / 2, 3 * M_PI / 2);
        cairo_arc(cr, bar_x + fill_width - bar_radius, bar_y + bar_radius, bar_radius, 3 * M_PI / 2, M_PI / 2);
        cairo_close_path(cr);
        cairo_fill(cr);
        cairo_pattern_destroy(progress_grad);

        // Glow at the end of progress bar
        double glow_x = bar_x + fill_width;
        cairo_pattern_t *end_glow = cairo_pattern_create_radial(glow_x, bar_y + bar_radius, 0, glow_x, bar_y + bar_radius, 15);
        cairo_pattern_add_color_stop_rgba(end_glow, 0.0, 0.75, 0.79, 0.98, 0.6);
        cairo_pattern_add_color_stop_rgba(end_glow, 1.0, 0.75, 0.79, 0.98, 0.0);
        cairo_set_source(cr, end_glow);
        cairo_arc(cr, glow_x, bar_y + bar_radius, 15, 0, 2 * M_PI);
        cairo_fill(cr);
        cairo_pattern_destroy(end_glow);

        // Shimmer effect
        double shimmer_cycle = fmod(elapsed * 0.8, 1.5);
        if (shimmer_cycle < 1.0) {
            double shimmer_x = bar_x + shimmer_cycle * fill_width;
            cairo_pattern_t *shimmer = cairo_pattern_create_linear(shimmer_x - 30, 0, shimmer_x + 30, 0);
            cairo_pattern_add_color_stop_rgba(shimmer, 0.0, 1, 1, 1, 0.0);
            cairo_pattern_add_color_stop_rgba(shimmer, 0.5, 1, 1, 1, 0.4);
            cairo_pattern_add_color_stop_rgba(shimmer, 1.0, 1, 1, 1, 0.0);
            cairo_set_source(cr, shimmer);

            cairo_new_path(cr);
            cairo_arc(cr, bar_x + bar_radius, bar_y + bar_radius, bar_radius, M_PI / 2, 3 * M_PI / 2);
            cairo_arc(cr, bar_x + fill_width - bar_radius, bar_y + bar_radius, bar_radius, 3 * M_PI / 2, M_PI / 2);
            cairo_close_path(cr);
            cairo_fill(cr);
            cairo_pattern_destroy(shimmer);
        }
    }

    // Status message (stage description)
    cairo_set_font_size(cr, 13);
    cairo_set_source_rgba(cr, 0.66, 0.69, 0.84, 0.9);
    const char *stage_msg = stage_messages[splash->current_stage];
    cairo_text_extents(cr, stage_msg, &extents);
    cairo_move_to(cr, cx - extents.width / 2.0, bar_y + bar_height + 24);
    cairo_show_text(cr, stage_msg);

    // Detail text (if any)
    if (splash->detail_text[0] != '\0') {
        cairo_set_font_size(cr, 11);
        cairo_set_source_rgba(cr, 0.56, 0.59, 0.73, 0.7);
        cairo_text_extents(cr, splash->detail_text, &extents);
        cairo_move_to(cr, cx - extents.width / 2.0, bar_y + bar_height + 42);
        cairo_show_text(cr, splash->detail_text);
    }

    // Version info at bottom
    cairo_set_font_size(cr, 10);
    cairo_set_source_rgba(cr, 0.34, 0.37, 0.53, 0.6);
    cairo_text_extents(cr, "v0.1.0", &extents);
    cairo_move_to(cr, cx - extents.width / 2.0, h - 12);
    cairo_show_text(cr, "v0.1.0");

    // Apply fade effect if closing
    if (splash->closing) {
        cairo_pop_group_to_source(cr);
        cairo_paint_with_alpha(cr, splash->fade_alpha);
    }
}

static gboolean animate_progress(gpointer user_data) {
    SplashScreen *splash = (SplashScreen*)user_data;

    // Calculate delta time
    static gint64 last_time = 0;
    gint64 now = g_get_monotonic_time();
    double dt = (last_time > 0) ? (now - last_time) / 1000000.0 : 0.016;
    last_time = now;

    // Update particles
    update_particles(splash, dt);

    // Smooth progress animation (ease out)
    float diff = splash->target_progress - splash->current_progress;
    if (fabs(diff) > 0.001f) {
        splash->current_progress += diff * 0.12f;
    }

    // Handle fade out
    if (splash->closing) {
        splash->fade_alpha -= 0.04f;
        if (splash->fade_alpha <= 0.0f) {
            gtk_window_destroy(GTK_WINDOW(splash->window));
            g_free(splash);
            return G_SOURCE_REMOVE;
        }
    }

    // Always redraw for animations
    gtk_widget_queue_draw(splash->drawing_area);

    return G_SOURCE_CONTINUE;
}

SplashScreen* splash_screen_new(void) {
    SplashScreen *splash = g_new0(SplashScreen, 1);

    splash->current_progress = 0.0f;
    splash->target_progress = 0.0f;
    splash->current_stage = SPLASH_STAGE_INIT;
    splash->detail_text[0] = '\0';
    splash->start_time = g_get_monotonic_time();
    splash->closing = FALSE;
    splash->fade_alpha = 1.0f;

    // Initialize particle system
    srand((unsigned int)splash->start_time);
    init_particles(splash);

    // Create window
    splash->window = gtk_window_new();
    gtk_window_set_title(GTK_WINDOW(splash->window), "DAW");
    gtk_window_set_default_size(GTK_WINDOW(splash->window), 480, 320);
    gtk_window_set_resizable(GTK_WINDOW(splash->window), FALSE);
    gtk_window_set_decorated(GTK_WINDOW(splash->window), FALSE);

    // Drawing area fills entire window - all rendering done in Cairo
    splash->drawing_area = gtk_drawing_area_new();
    gtk_drawing_area_set_draw_func(GTK_DRAWING_AREA(splash->drawing_area),
                                    draw_splash, splash, NULL);
    gtk_window_set_child(GTK_WINDOW(splash->window), splash->drawing_area);

    // Start animation timer (60 fps)
    splash->animation_timer = g_timeout_add(16, animate_progress, splash);

    // Show window
    gtk_window_present(GTK_WINDOW(splash->window));

    return splash;
}

void splash_screen_set_stage(SplashScreen *splash, SplashStage stage, const char *detail) {
    if (!splash || stage >= SPLASH_STAGE_COUNT) return;

    splash->current_stage = stage;
    splash->target_progress = stage_progress[stage];

    if (detail) {
        strncpy(splash->detail_text, detail, sizeof(splash->detail_text) - 1);
        splash->detail_text[sizeof(splash->detail_text) - 1] = '\0';
    } else {
        splash->detail_text[0] = '\0';
    }
}

void splash_screen_set_message(SplashScreen *splash, const char *message) {
    if (!splash || !message) return;
    strncpy(splash->detail_text, message, sizeof(splash->detail_text) - 1);
    splash->detail_text[sizeof(splash->detail_text) - 1] = '\0';
}

void splash_screen_update(SplashScreen *splash) {
    if (!splash) return;

    // Process pending GTK events to update display
    while (g_main_context_pending(NULL)) {
        g_main_context_iteration(NULL, FALSE);
    }
}

void splash_screen_close(SplashScreen *splash) {
    if (!splash) return;

    // Set to 100% before fading
    splash->target_progress = 1.0f;
    splash->current_progress = 1.0f;
    splash_screen_set_stage(splash, SPLASH_STAGE_COMPLETE, NULL);

    // Brief pause to show completion
    splash_screen_update(splash);
    g_usleep(400000);  // 400ms to appreciate the completion

    // Start fade out
    splash->closing = TRUE;
}

gboolean splash_screen_is_visible(SplashScreen *splash) {
    if (!splash) return FALSE;
    return !splash->closing || splash->fade_alpha > 0.0f;
}
