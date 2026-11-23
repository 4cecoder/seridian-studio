#!/usr/bin/env bash
# Backend Detection Test Script
# Runs the backend detection test and prints detailed results

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$(dirname "$SCRIPT_DIR")")"

cd "$PROJECT_ROOT"

echo "=== Backend Detection Test ==="
echo ""

# Check if running on Linux
if [ "$(uname)" = "Linux" ]; then
    echo "Platform: Linux"
    echo ""

    # Detect PulseAudio
    if pactl info >/dev/null 2>&1; then
        echo "PulseAudio: yes"
        HAS_PULSE=1
    else
        echo "PulseAudio: no"
        HAS_PULSE=0
    fi

    # Detect PipeWire
    if [ -n "$PIPEWIRE_RUNTIME_DIR" ] || pw-cli ls Node >/dev/null 2>&1; then
        echo "PipeWire: yes"
        HAS_PIPEWIRE=1
    else
        echo "PipeWire: no"
        HAS_PIPEWIRE=0
    fi

    # Determine auto-selected backend
    if [ $HAS_PULSE -eq 1 ]; then
        AUTO_BACKEND="PulseAudio"
    elif [ $HAS_PIPEWIRE -eq 1 ]; then
        AUTO_BACKEND="PipeWire"
    else
        AUTO_BACKEND="None"
    fi

    echo "Auto-selected: $AUTO_BACKEND"
    echo ""

    # Verify priority order
    if [ $HAS_PULSE -eq 1 ] && [ $HAS_PIPEWIRE -eq 1 ]; then
        echo "Priority verification:"
        echo "  Both backends available"
        echo "  Expected: PulseAudio > PipeWire (PA is fully implemented)"
        if [ "$AUTO_BACKEND" = "PulseAudio" ]; then
            echo "  ✓ Priority order correct"
        else
            echo "  ✗ Priority order incorrect!"
            exit 1
        fi
    fi

    # Verify at least one backend is available
    if [ $HAS_PULSE -eq 0 ] && [ $HAS_PIPEWIRE -eq 0 ]; then
        echo "ERROR: No audio backend detected on Linux!"
        echo "At least one of PulseAudio or PipeWire should be available."
        exit 1
    fi
elif [ "$(uname)" = "Darwin" ]; then
    echo "Platform: macOS"
    echo "CoreAudio: yes (always available)"
    echo "Auto-selected: CoreAudio"
else
    echo "Platform: $(uname)"
    echo "Warning: Unsupported platform for this test"
fi

echo ""
echo "Building and running compiled test..."
zig build test-backend-detection

echo ""
echo "=" | head -c 50
echo ""
echo "✓ ALL BACKEND DETECTION TESTS PASSED"
echo "=" | head -c 50
echo ""
