#!/bin/bash
# Run the actual playback test
# This test verifies that REAL audio comes out of speakers

set -e

echo "Building actual playback test..."
zig build test-actual-playback

echo ""
echo "Test complete!"
echo ""
echo "Did you hear a 440Hz tone (musical note A4)?"
echo "If YES: Audio playback is working end-to-end!"
echo "If NO: There may be an issue with your audio system or PulseAudio."
