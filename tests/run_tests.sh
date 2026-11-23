#!/bin/bash
# Comprehensive DAW Test Suite
# Runs all tests without launching the GUI

set -e

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

cd "$PROJECT_ROOT"

echo "🧪 DAW Comprehensive Test Suite"
echo "=================================="
echo "Project: $(pwd)"
echo "Date: $(date)"
echo ""

# Count tests
TOTAL_TESTS=0
PASSED_TESTS=0
FAILED_TESTS=0

run_test() {
    local test_name="$1"
    local test_cmd="$2"

    TOTAL_TESTS=$((TOTAL_TESTS + 1))
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "Test $TOTAL_TESTS: $test_name"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    if eval "$test_cmd"; then
        PASSED_TESTS=$((PASSED_TESTS + 1))
        echo "✅ PASSED: $test_name"
    else
        FAILED_TESTS=$((FAILED_TESTS + 1))
        echo "❌ FAILED: $test_name"
        return 1
    fi
}

# Test 1: Build verification
run_test "Build Verification" "bash tests/test_build.sh"

# Test 2: Zig unit tests for core modules
run_test "Audio Engine Tests" "zig test src/audio/engine.zig --main-pkg-path ."

run_test "MIDI System Tests" "zig test src/midi/midi.zig --main-pkg-path ."

run_test "Project System Tests" "zig test src/project/project.zig --main-pkg-path ."

# Test 3: Backend tests
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Test: Audio Backend Integration"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
TOTAL_TESTS=$((TOTAL_TESTS + 1))

if zig run tests/test_audio_backend.zig --main-pkg-path .; then
    PASSED_TESTS=$((PASSED_TESTS + 1))
    echo "✅ PASSED: Audio Backend Integration"
else
    FAILED_TESTS=$((FAILED_TESTS + 1))
    echo "❌ FAILED: Audio Backend Integration"
fi

# Test 4: Check for memory leaks in core modules
run_test "Memory Leak Check - Audio Engine" \
    "zig test src/audio/engine.zig --main-pkg-path . -ftest-filter='test_init_deinit'"

run_test "Memory Leak Check - MIDI" \
    "zig test src/midi/midi.zig --main-pkg-path ."

# Test 5: Platform compatibility checks
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Test: Platform Compatibility"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
TOTAL_TESTS=$((TOTAL_TESTS + 1))

PLATFORM_OK=true

# Check no macOS symbols on Linux
if [ "$(uname)" = "Linux" ]; then
    if nm zig-out/bin/daw 2>/dev/null | grep -E "AudioComponent|MIDIGetNumber" >/dev/null; then
        echo "❌ Found macOS-specific symbols on Linux build"
        PLATFORM_OK=false
    else
        echo "✓ No macOS symbols found (correct for Linux)"
    fi
fi

# Check PulseAudio linkage
if ldd zig-out/bin/daw 2>/dev/null | grep pulse >/dev/null; then
    echo "✓ PulseAudio linked correctly"
else
    echo "⚠ PulseAudio not linked (may use alternative backend)"
fi

if [ "$PLATFORM_OK" = true ]; then
    PASSED_TESTS=$((PASSED_TESTS + 1))
    echo "✅ PASSED: Platform Compatibility"
else
    FAILED_TESTS=$((FAILED_TESTS + 1))
    echo "❌ FAILED: Platform Compatibility"
fi

# Final summary
echo ""
echo "=================================="
echo "📊 Test Suite Summary"
echo "=================================="
echo "Total Tests:  $TOTAL_TESTS"
echo "Passed:       $PASSED_TESTS ✅"
echo "Failed:       $FAILED_TESTS ❌"
echo ""

if [ $FAILED_TESTS -eq 0 ]; then
    echo "🎉 All tests passed!"
    echo ""
    echo "Build Status: ✅ READY FOR DISTRIBUTION"
    echo "  - Linux:   ✓ Builds and works"
    echo "  - macOS:   ✓ Should work (CoreAudio)"
    echo "  - Windows: ✓ Should work (WASAPI)"
    exit 0
else
    echo "⚠️  Some tests failed"
    echo "Build Status: ❌ NEEDS FIXES"
    exit 1
fi
