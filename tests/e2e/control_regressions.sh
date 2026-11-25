#!/usr/bin/env bash
# Regression tests for the socket control path (docs/QA.md B11, B15, B16).
#
# Starts the headless app in a private XDG_RUNTIME_DIR (never touches a live
# session), drives it through the real `seridian` CLI and the raw socket, and
# kills only the pid it started.
#
# Usage: tests/e2e/control_regressions.sh [test-name ...]
#   tests: open_restores_bpm_and_master, relative_paths_are_absolute, one_command_per_request
# Requires: zig-out/bin/seridian and zig-out/bin/seridian-studio-headless
#   (zig build -Dheadless=true), jq, python3. Exit code 0 when all selected tests pass.

set -u

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CLI="$ROOT/zig-out/bin/seridian"
APP="$ROOT/zig-out/bin/seridian-studio-headless"
PASSED=0
FAILED=0
APP_PID=""
RUNTIME=""
WORK=""

pass() { PASSED=$((PASSED + 1)); echo "  [PASS] $1"; }
fail() { FAILED=$((FAILED + 1)); echo "  [FAIL] $1"; }

cleanup() {
    if [ -n "$APP_PID" ]; then kill "$APP_PID" 2>/dev/null; fi
    if [ -n "$WORK" ]; then rm -rf "$WORK"; fi
    if [ -n "$RUNTIME" ]; then rm -rf "$RUNTIME"; fi
}
trap cleanup EXIT

for need in "$CLI" "$APP"; do
    if [ ! -x "$need" ]; then
        echo "missing $need; build with 'zig build -Dheadless=true'"
        exit 1
    fi
done

RUNTIME="$(mktemp -d)"
chmod 700 "$RUNTIME"
WORK="$(mktemp -d)"
export XDG_RUNTIME_DIR="$RUNTIME"
unset DISPLAY WAYLAND_DISPLAY HYPRLAND_INSTANCE_SIGNATURE

# The app's working directory is a directory of its own, so a path resolved in
# the app's directory is told apart from one resolved in the CLI's.
APP_CWD="$WORK/appcwd"
mkdir -p "$APP_CWD"
(cd "$APP_CWD" && "$APP" >"$WORK/app.log" 2>&1 &
 echo $! >"$WORK/app.pid")
APP_PID="$(cat "$WORK/app.pid")"

STATE="$RUNTIME/seridian-state.json"
if ! "$CLI" state --wait-ms 20000 >/dev/null 2>&1; then
    echo "app did not publish a state snapshot; log:"
    cat "$WORK/app.log"
    exit 1
fi

state_field() { "$CLI" state >/dev/null 2>&1; jq -r "$1" "$STATE"; }

# Sends raw bytes to the control socket and prints the reply line.
raw_send() {
    python3 -I - "$RUNTIME/seridian.sock" "$1" <<'PY'
import socket, sys
s = socket.socket(socket.AF_UNIX)
s.connect(sys.argv[1])
s.sendall(sys.argv[2].encode("latin-1").decode("unicode_escape").encode("latin-1"))
s.settimeout(10)
print(s.makefile().readline().strip())
PY
}

test_open_restores_bpm_and_master() {
    echo "== open restores bpm and master volume (B11)"
    local dir="$WORK/b11"
    "$CLI" bpm 150 >/dev/null && "$CLI" save "$dir" >/dev/null || { fail "save"; return; }
    sed -i -e 's/^bpm = .*/bpm = 90.00/' -e 's/^master_volume = .*/master_volume = 0.4000/' "$dir/project.daw"
    "$CLI" bpm 77 >/dev/null
    "$CLI" open "$dir" >/dev/null || { fail "open"; return; }
    local bpm master
    bpm="$(state_field .bpm)"
    master="$(state_field .master_gain)"
    awk -v v="$bpm" 'BEGIN { exit !(v > 89.9 && v < 90.1) }' && pass "bpm restored to 90 (got $bpm)" || fail "bpm restored to 90 (got $bpm)"
    awk -v v="$master" 'BEGIN { exit !(v > 0.39 && v < 0.41) }' && pass "master volume restored to 0.4 (got $master)" || fail "master volume restored to 0.4 (got $master)"
}

test_relative_paths_are_absolute() {
    echo "== relative save and export paths use the CLI's directory (B15)"
    local cli_cwd="$WORK/clicwd"
    mkdir -p "$cli_cwd"
    (cd "$cli_cwd" && "$CLI" save relsession >/dev/null && "$CLI" export rel.wav >/dev/null) || { fail "save and export reply ok"; return; }
    [ -f "$cli_cwd/relsession/project.daw" ] && pass "save wrote into the CLI's directory" || fail "save wrote into the CLI's directory"
    [ -f "$cli_cwd/rel.wav" ] && pass "export wrote into the CLI's directory" || fail "export wrote into the CLI's directory"
    [ ! -e "$APP_CWD/relsession" ] && [ ! -e "$APP_CWD/rel.wav" ] && pass "nothing landed in the app's directory" || fail "nothing landed in the app's directory"
}

test_one_command_per_request() {
    echo "== several lines in one write are rejected (B16)"
    "$CLI" bpm 100 >/dev/null
    local reply
    reply="$(raw_send 'bpm 111\nbpm 222\n')"
    case "$reply" in
        ok*) fail "two lines in one write must not reply ok (got: $reply)" ;;
        *) pass "two lines in one write rejected (got: $reply)" ;;
    esac
    local bpm
    bpm="$(state_field .bpm)"
    awk -v v="$bpm" 'BEGIN { exit !(v > 99.9 && v < 100.1) }' && pass "no line of a rejected request ran (bpm $bpm)" || fail "no line of a rejected request ran (bpm $bpm)"
    reply="$(raw_send 'bpm 133\0junk\n')"
    case "$reply" in
        ok*) fail "an embedded NUL must not reply ok (got: $reply)" ;;
        *) pass "embedded NUL rejected (got: $reply)" ;;
    esac
}

ALL="open_restores_bpm_and_master relative_paths_are_absolute one_command_per_request"
SELECTED="${*:-$ALL}"
for name in $SELECTED; do
    "test_$name"
done

echo "passed: $PASSED, failed: $FAILED"
[ "$FAILED" -eq 0 ]
