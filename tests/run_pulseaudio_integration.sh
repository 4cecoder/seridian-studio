#!/bin/bash
# Run PulseAudio Integration Test
# This test verifies that the engine and PulseAudio backend work together end-to-end

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR/.."

echo "Running PulseAudio Integration Test..."
echo ""

# Run from src directory to enable audio/engine.zig import
cd src
zig run -lc -lpulse -lpulse-simple ../tests/test_pulseaudio_integration.zig
EXIT_CODE=$?

echo ""
if [ $EXIT_CODE -eq 0 ]; then
    echo "SUCCESS: PulseAudio integration test passed!"
else
    echo "FAILURE: PulseAudio integration test failed (exit code $EXIT_CODE)"
fi

exit $EXIT_CODE
