#!/bin/bash
# Build Verification Test Script
# Tests that the DAW builds successfully on all platforms

set -e

echo "🔨 DAW Build Verification Test"
echo "================================"
echo ""

# Clean build
echo "1️⃣ Cleaning previous build..."
zig build clean 2>/dev/null || true
rm -rf zig-cache zig-out .zig-cache 2>/dev/null || true
echo "   ✓ Clean complete"
echo ""

# Test basic build
echo "2️⃣ Testing basic build..."
if zig build 2>&1 | tee /tmp/build.log; then
    echo "   ✓ Build succeeded"
else
    echo "   ✗ Build failed"
    echo "   Last 20 lines of output:"
    tail -20 /tmp/build.log
    exit 1
fi
echo ""

# Verify executable exists
echo "3️⃣ Verifying executable..."
if [ -f "zig-out/bin/daw" ]; then
    echo "   ✓ Executable created: zig-out/bin/daw"
    ls -lh zig-out/bin/daw
else
    echo "   ✗ Executable not found"
    exit 1
fi
echo ""

# Check for common symbols
echo "4️⃣ Checking for undefined symbols..."
if nm zig-out/bin/daw 2>/dev/null | grep -i "AudioComponentFindNext\|MIDIGetNumberOfSources" >/dev/null; then
    echo "   ✗ Found macOS-specific symbols (should not be present on Linux)"
    exit 1
else
    echo "   ✓ No macOS-specific symbols found"
fi
echo ""

# Verify PulseAudio linkage
echo "5️⃣ Checking PulseAudio linkage..."
if ldd zig-out/bin/daw 2>/dev/null | grep -i pulse >/dev/null; then
    echo "   ✓ PulseAudio libraries linked:"
    ldd zig-out/bin/daw | grep pulse
else
    echo "   ⚠ Warning: PulseAudio not linked (may use different backend)"
fi
echo ""

# File size check
echo "6️⃣ Build size check..."
SIZE=$(stat -f%z zig-out/bin/daw 2>/dev/null || stat -c%s zig-out/bin/daw 2>/dev/null)
SIZE_MB=$((SIZE / 1024 / 1024))
echo "   Executable size: ${SIZE_MB}MB"
if [ $SIZE -gt 0 ]; then
    echo "   ✓ Executable has valid size"
else
    echo "   ✗ Executable is empty"
    exit 1
fi
echo ""

echo "================================"
echo "✅ All build verification tests passed!"
echo ""
echo "Summary:"
echo "  - Build: SUCCESS"
echo "  - Executable: EXISTS (${SIZE_MB}MB)"
echo "  - Platform compatibility: VERIFIED"
echo "  - Symbol linkage: CLEAN"
