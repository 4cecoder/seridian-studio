/**
 * DAW Splash Screen - Loading screen with real progress tracking
 *
 * Shows initialization progress with:
 * - Animated logo/title
 * - Step-by-step progress messages
 * - Smooth progress bar
 * - Visual flair (glow effects, fade transitions)
 *
 * Tokyo Night themed to match the main application.
 */

#ifndef SPLASH_SCREEN_GTK_H
#define SPLASH_SCREEN_GTK_H

#include <gtk/gtk.h>

// Initialization stages with progress percentages
typedef enum {
    SPLASH_STAGE_INIT = 0,           // 0%   - Starting up
    SPLASH_STAGE_CONFIG,             // 10%  - Loading configuration
    SPLASH_STAGE_AUDIO_ENGINE,       // 25%  - Initializing audio engine
    SPLASH_STAGE_AUDIO_BACKEND,      // 40%  - Connecting audio backend
    SPLASH_STAGE_MIDI,               // 55%  - Initializing MIDI
    SPLASH_STAGE_PROJECT,            // 70%  - Loading project system
    SPLASH_STAGE_UI_THEME,           // 80%  - Loading theme
    SPLASH_STAGE_UI_WINDOW,          // 90%  - Creating main window
    SPLASH_STAGE_COMPLETE,           // 100% - Ready
    SPLASH_STAGE_COUNT
} SplashStage;

// Splash screen context
typedef struct SplashScreen SplashScreen;

/**
 * Create and show the splash screen
 * Must be called after gtk_init()
 *
 * @return Splash screen handle
 */
SplashScreen* splash_screen_new(void);

/**
 * Update splash screen to a new stage
 * Animates progress bar and updates message
 *
 * @param splash  The splash screen
 * @param stage   New initialization stage
 * @param detail  Optional detail message (NULL for default)
 */
void splash_screen_set_stage(SplashScreen *splash, SplashStage stage, const char *detail);

/**
 * Set a custom status message without changing stage
 *
 * @param splash   The splash screen
 * @param message  Status message to display
 */
void splash_screen_set_message(SplashScreen *splash, const char *message);

/**
 * Process pending GTK events to update splash display
 * Call this after each stage update
 */
void splash_screen_update(SplashScreen *splash);

/**
 * Fade out and destroy the splash screen
 * Should be called when initialization is complete
 *
 * @param splash  The splash screen to close
 */
void splash_screen_close(SplashScreen *splash);

/**
 * Check if splash screen is still visible
 */
gboolean splash_screen_is_visible(SplashScreen *splash);

#endif // SPLASH_SCREEN_GTK_H
