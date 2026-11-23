#!/usr/bin/env bash

# DAW Launcher with AAA-style Graphics Configuration
# Usage: sh run.sh [--gl|--vulkan|--cairo|--config <file>]

CONFIG_FILE="daw.conf"
FORCE_BACKEND=""
FORCE_RENDERER=""

# Pin the Zig toolchain. The project builds with 0.18.0-dev.738. The default
# `zig` on some machines is another dev build, and Raven's Zig translation
# does not build with it. SERIDIAN_ZIG_DIR overrides the directory.
ZIG_PINNED_DIR="${SERIDIAN_ZIG_DIR:-$HOME/.local/share/zig/dev738/zig-x86_64-linux-0.18.0-dev.738+ae9a8acc7}"
if [ -x "$ZIG_PINNED_DIR/zig" ]; then
    PATH="$ZIG_PINNED_DIR:$PATH"
    export PATH
fi
ZIG_VERSION="$(zig version 2>/dev/null)"
case "$ZIG_VERSION" in
    0.18.0-dev.738*) ;;
    *)
        echo "✗ Zig 0.18.0-dev.738 is required, found '${ZIG_VERSION:-none}'." >&2
        echo "  Install it or set SERIDIAN_ZIG_DIR to the directory that contains zig." >&2
        exit 1 ;;
esac

# Parse arguments
while [ $# -gt 0 ]; do
    case "$1" in
        --x11) shift ;;  # accepted for compatibility; X11 is now the default path
        --wayland)
            echo "✗ --wayland is not supported: Raven renders through X11 (use XWayland via DISPLAY)" >&2
            exit 1 ;;
        --gl) FORCE_RENDERER="gl"; shift ;;
        --vulkan) FORCE_RENDERER="vulkan"; shift ;;
        --cairo) FORCE_RENDERER="cairo"; shift ;;
        --config) CONFIG_FILE="$2"; shift 2 ;;
        *) break ;;
    esac
done

# Load config file (if exists)
if [ -f "$CONFIG_FILE" ]; then
    echo "📋 Loading config: $CONFIG_FILE"

    # Simple INI parser
    RENDERER_PREF=$(grep -A10 "\[Graphics\]" "$CONFIG_FILE" | grep "^renderer=" | cut -d'=' -f2)
    GPU_PREF=$(grep -A10 "\[Graphics\]" "$CONFIG_FILE" | grep "^gpu=" | cut -d'=' -f2)
    SHOW_INFO=$(grep -A5 "\[Debug\]" "$CONFIG_FILE" | grep "^show_backend_info=" | cut -d'=' -f2)

    # Report keys this script does not read, so a typo or an unsupported
    # setting is visible instead of silently ignored. Accepted keys are the
    # ones read above: [Graphics] renderer, gpu and [Debug] show_backend_info.
    SECTION=""
    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in
            ""|\#*|\;*) continue ;;
            \[*\]) SECTION="${line#\[}"; SECTION="${SECTION%\]}"; continue ;;
            *=*) ;;
            *) continue ;;
        esac
        key="${line%%=*}"
        value="${line#*=}"
        case "$SECTION:$key" in
            Graphics:renderer|Graphics:gpu|Debug:show_backend_info) ;;
            *)
                echo "⚠ $CONFIG_FILE: unknown key '$key' in section [${SECTION:-none}] is ignored." >&2
                echo "  Accepted keys: [Graphics] renderer, gpu; [Debug] show_backend_info." >&2 ;;
        esac
        if [ "$key" = "backend" ] && [ "$value" = "wayland" ]; then
            echo "⚠ $CONFIG_FILE: backend=wayland is not supported: Raven renders through X11." >&2
            echo "  The setting is ignored; the app runs under XWayland via DISPLAY." >&2
        fi
    done < "$CONFIG_FILE"

    # Use config values if not overridden by CLI
    [ -z "$FORCE_RENDERER" ] && FORCE_RENDERER="$RENDERER_PREF"
fi

# Default values
[ -z "$FORCE_RENDERER" ] && FORCE_RENDERER="gl"
[ -z "$GPU_PREF" ] && GPU_PREF="nvidia"
[ -z "$SHOW_INFO" ] && SHOW_INFO="true"

# Display path, chosen from the session environment. Raven uses its X11 backend,
# so a Wayland session runs the app under XWayland through DISPLAY.
#   WAYLAND_DISPLAY and DISPLAY set -> XWayland
#   only DISPLAY set                -> X11
#   neither                         -> error
if [ "$SERIDIAN_HEADLESS" = "1" ]; then
    # Headless build: Raven's null platform, no window, no display needed.
    echo "✓ Headless mode (SERIDIAN_HEADLESS=1): skipping the display check"
elif [ -n "$DISPLAY" ]; then
    if [ -n "$WAYLAND_DISPLAY" ]; then
        echo "✓ Using X11 backend via XWayland (DISPLAY=$DISPLAY, WAYLAND_DISPLAY=$WAYLAND_DISPLAY)"
    else
        echo "✓ Using X11 backend (DISPLAY=$DISPLAY)"
    fi
    export GDK_BACKEND=x11
else
    echo "✗ No display found: DISPLAY is not set." >&2
    echo "  Start an X server, or run under a Wayland session with XWayland enabled." >&2
    exit 1
fi

# Audio: point PulseAudio/PipeWire at the user session server when not set, so the
# app selects a real backend instead of the silent null backend.
if [ -z "$PULSE_SERVER" ]; then
    export PULSE_SERVER="unix:/run/user/$(id -u)/pulse/native"
fi

# GTK4 Rendering Setup
# The app runs the seridian CLI for window placement and monitor queries.
SERIDIAN_CLI="$(pwd)/zig-out/bin/seridian"
export SERIDIAN_CLI

export GSK_RENDERER="$FORCE_RENDERER"

if [ "$FORCE_RENDERER" = "gl" ]; then
    export GDK_DEBUG=gl-prefer-gl
fi

# GPU-specific settings
if [ "$GPU_PREF" = "nvidia" ]; then
    export __GLX_VENDOR_LIBRARY_NAME=nvidia
    export __GL_GSYNC_ALLOWED=1
    export __GL_VRR_ALLOWED=1
fi

# Show configuration (if enabled)
if [ "$SHOW_INFO" = "true" ]; then
    echo "🎮 DAW Launch Configuration"
    echo "   Display Backend: $GDK_BACKEND"
    echo "   Renderer: $GSK_RENDERER"
    echo "   GPU: $GPU_PREF"
    echo ""
fi

# Build and run. The app log is saved for `seridian logs`. The exit status of
# `zig build run` is written to a file because `sh` has no pipefail to read it
# through the pipe to tee.
LOG_FILE="${XDG_RUNTIME_DIR:-/tmp}/seridian-app.log"
STATUS_FILE="${XDG_RUNTIME_DIR:-/tmp}/seridian-app.status"
if [ "$SERIDIAN_HEADLESS" = "1" ]; then
    # Build the headless artifact, then run it directly (the `run` step runs the GUI binary).
    { zig build -Dheadless=true "$@" 2>&1 && ./zig-out/bin/seridian-studio-headless 2>&1; echo "$?" > "$STATUS_FILE"; } | tee "$LOG_FILE"
    exit "$(cat "$STATUS_FILE")"
fi
{ zig build run "$@" 2>&1; echo "$?" > "$STATUS_FILE"; } | tee "$LOG_FILE"
exit "$(cat "$STATUS_FILE")"
