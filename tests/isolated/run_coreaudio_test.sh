#!/bin/bash
# Run CoreAudio isolated runtime test
# This script uses the zig build system to compile and run the isolated test

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

echo "============================================================"
echo "CoreAudio Backend Isolated Test Runner"
echo "============================================================"
echo ""
echo "Project root: $PROJECT_ROOT"
echo ""

cd "$PROJECT_ROOT"

echo "[1/2] Building test using zig build..."
echo ""

zig build test-coreaudio-isolated
TEST_EXIT_CODE=$?

echo ""
echo "[2/2] Test execution completed"
echo ""

# Report results
if [ $TEST_EXIT_CODE -eq 0 ]; then
    echo "============================================================"
    echo "SUCCESS - All tests passed (exit code 0)"
    echo "============================================================"
    exit 0
else
    echo "============================================================"
    echo "FAILURE - Tests failed (exit code $TEST_EXIT_CODE)"
    echo "============================================================"
    exit 1
fi
