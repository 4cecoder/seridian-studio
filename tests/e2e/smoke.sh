#!/usr/bin/env bash
# End-to-end smoke test for Seridian Studio.
#
# Drives the real app through the `seridian` CLI on an X display:
#   1. starts the app (if not already running) and waits for its window
#   2. waits for the state snapshot and checks the initial mixer state
#   3. drags Track 1's pan knob and checks the engine actually changed
#   4. double-clicks the knob and checks it returns to centre
#   5. takes a screenshot as a debugging artifact
#   6. piano roll: note add/remove by click, track combo reload, computer keys
#      (needs TAB_X/TAB_Y, ROLL_X/ROLL_Y, TRACK_COMBO_X/TRACK_COMBO_Y from env;
#      skipped when unset because they are not calibrated against the layout)
#
# Usage: tests/e2e/smoke.sh [artifact-dir]
# Requires: a running X display (DISPLAY), PulseAudio/PipeWire, xdotool, xwd, ffmpeg.
# Exit code: 0 on success, 1 on any failed check.

set -u

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CLI="$ROOT/zig-out/bin/seridian"
ARTIFACTS="${1:-${XDG_RUNTIME_DIR:-/tmp}/seridian-e2e}"
STATE_FILE="${XDG_RUNTIME_DIR:-/tmp}/seridian-state.json"
PASSED=0
FAILED=0

mkdir -p "$ARTIFACTS"

pass() { PASSED=$((PASSED + 1)); echo "  [PASS] $1"; }
fail() { FAILED=$((FAILED + 1)); echo "  [FAIL] $1"; }

# Reads one numeric field from track 0 of the state snapshot.
track0_field() {
    jq -r ".tracks[0].$1" "$STATE_FILE"
}

# Reads midi_notes (MIDI note count) of one track from the state snapshot.
track_midi_notes() {
    jq -r ".tracks[$1].midi_notes" "$STATE_FILE"
}

# True when a value is a non-negative integer.
is_count() {
    case "$1" in
        ''|*[!0-9]*) return 1 ;;
        *) return 0 ;;
    esac
}

# True when two floats differ by more than `tolerance`.
differs() {
    awk -v a="$1" -v b="$2" -v t="$3" 'BEGIN { d = a - b; if (d < 0) d = -d; exit !(d > t) }'
}

cleanup() {
    if [ "${STARTED_APP:-0}" = "1" ]; then
        pkill -x seridian-studio 2>/dev/null || true
    fi
}
trap cleanup EXIT

if [ ! -x "$CLI" ]; then
    echo "missing $CLI; run 'zig build' first"
    exit 1
fi

echo "== setup"
if "$CLI" status >/dev/null 2>&1; then
    echo "  app already running"
else
    (cd "$ROOT" && nohup sh run.sh --x11 >"$ARTIFACTS/app.log" 2>&1 &)
    STARTED_APP=1
    echo "  started app, log: $ARTIFACTS/app.log"
fi

if ! "$CLI" state --wait-ms 15000 >/dev/null 2>&1; then
    fail "state snapshot appeared within 15s"
    exit 1
fi
pass "state snapshot appeared"

W="$("$CLI" status 2>/dev/null | sed -n 's/^window: //p')"
if [ -z "$W" ]; then
    fail "app window found"
    exit 1
fi
pass "app window found ($W)"

# Wait until layout has placed the pan knob, then read its centre from the snapshot.
# The window size is set by the window manager, so coordinates are never hard-coded.
KNOB_X=""
KNOB_Y=""
for _ in $(seq 1 60); do
    kx="$(jq -r '.tracks[0].pan_knob.x // 0' "$STATE_FILE" 2>/dev/null)"
    if awk -v x="${kx:-0}" 'BEGIN { exit !(x > 0) }'; then
        KNOB_X="$(printf "%.0f" "$kx")"
        KNOB_Y="$(printf "%.0f" "$(jq -r '.tracks[0].pan_knob.y' "$STATE_FILE")")"
        break
    fi
    sleep 0.25
done
if [ -z "$KNOB_X" ]; then
    fail "pan knob reported its position in the snapshot"
    exit 1
fi
pass "pan knob at window ($KNOB_X, $KNOB_Y)"

echo "== initial state"
if [ "$(jq -r '.tracks | length' "$STATE_FILE")" = "8" ]; then
    pass "eight tracks reported"
else
    fail "eight tracks reported"
fi

start_pan="$(track0_field pan)"
echo "  track 1 pan = $start_pan"

echo "== drag pan knob"
"$CLI" drag "$KNOB_X" "$KNOB_Y" 0 -60 --steps 12 >/dev/null 2>&1 || fail "drag command ran"
sleep 1
after_drag="$(track0_field pan)"
echo "  track 1 pan after drag up = $after_drag"
if differs "$after_drag" "$start_pan" 0.05; then
    pass "pan changed after drag up"
else
    fail "pan changed after drag up"
fi
if awk -v a="$after_drag" -v b="$start_pan" 'BEGIN { exit !(a > b) }'; then
    pass "drag up moved pan right"
else
    fail "drag up moved pan right"
fi

echo "== double-click resets to centre"
"$CLI" click "$KNOB_X" "$KNOB_Y" --double >/dev/null 2>&1 || fail "double click ran"
sleep 1
reset_pan="$(track0_field pan)"
echo "  track 1 pan after reset = $reset_pan"
if awk -v p="$reset_pan" 'BEGIN { if (p < 0) p = -p; exit !(p < 0.01) }'; then
    pass "double-click reset pan to centre"
else
    fail "double-click reset pan to centre"
fi

echo "== fine drag (shift) calibration"
"$CLI" click "$KNOB_X" "$KNOB_Y" --double >/dev/null 2>&1 || fail "reset click ran"
sleep 1
before_fine="$(track0_field pan)"
"$CLI" drag "$KNOB_X" "$KNOB_Y" 0 -60 --steps 12 --shift >/dev/null 2>&1 || fail "shift drag ran"
sleep 1
fine_pan="$(track0_field pan)"
fine_delta="$(awk -v a="$fine_pan" -v b="$before_fine" 'BEGIN { printf "%.3f", a - b }')"
echo "  shift-drag 60 px moved pan by $fine_delta"
if awk -v d="$fine_delta" 'BEGIN { exit !(d > 0.10 && d < 0.14) }'; then
    pass "fine drag moves one fifth as far (about 0.12)"
else
    fail "fine drag moves one fifth as far (about 0.12)"
fi
if awk -v p="$after_drag" 'BEGIN { exit !(p > 0.55 && p < 0.65) }'; then
    pass "coarse drag 60 px moves pan about 0.6"
else
    fail "coarse drag 60 px moves pan about 0.6"
fi

echo "== piano roll"
# Window-relative pixels of the main-area tabs, the piano roll cells and the
# track combo. Not calibrated: they depend on the window size, so they come
# from the environment. Without them the checks below are skipped, not passed.
TAB_X="${TAB_X:-}"
TAB_Y="${TAB_Y:-}"
ROLL_X="${ROLL_X:-}"
ROLL_Y="${ROLL_Y:-}"
ROLL_STEP_X="${ROLL_STEP_X:-40}"
TRACK_COMBO_X="${TRACK_COMBO_X:-}"
TRACK_COMBO_Y="${TRACK_COMBO_Y:-}"
if [ -z "$TAB_X" ] || [ -z "$TAB_Y" ] || [ -z "$ROLL_X" ] || [ -z "$ROLL_Y" ]; then
    echo "  [SKIP] piano roll checks: set TAB_X, TAB_Y, ROLL_X, ROLL_Y (window-relative pixels) to run them"
else
    base_notes="$(track_midi_notes 0)"
    if is_count "$base_notes"; then
        pass "track 0 reports midi_notes ($base_notes)"
    else
        fail "track 0 reports midi_notes"
    fi

    "$CLI" click "$TAB_X" "$TAB_Y" >/dev/null 2>&1 || fail "piano roll tab click ran"
    sleep 1
    "$CLI" click "$ROLL_X" "$ROLL_Y" >/dev/null 2>&1 || fail "click on empty grid cell ran"
    sleep 1
    added_notes="$(track_midi_notes 0)"
    echo "  track 0 midi_notes after add = $added_notes (baseline $base_notes)"
    if [ "$added_notes" = "$((base_notes + 1))" ]; then
        pass "click on empty cell adds one note"
    else
        fail "click on empty cell adds one note"
    fi

    "$CLI" click "$ROLL_X" "$ROLL_Y" >/dev/null 2>&1 || fail "click on added note ran"
    sleep 1
    removed_notes="$(track_midi_notes 0)"
    echo "  track 0 midi_notes after removing it = $removed_notes"
    if [ "$removed_notes" = "$base_notes" ]; then
        pass "click on the note removes it"
    else
        fail "click on the note removes it"
    fi

    # The seridian CLI has no right-click option, so right-click removal is not checked.
    echo "  [SKIP] right-click removal: seridian CLI has no right-click option"

    ROLL_X2="$((ROLL_X + ROLL_STEP_X))"
    "$CLI" click "$ROLL_X" "$ROLL_Y" >/dev/null 2>&1 || fail "add first of two notes ran"
    sleep 1
    "$CLI" click "$ROLL_X2" "$ROLL_Y" >/dev/null 2>&1 || fail "add second of two notes ran"
    sleep 1
    two_notes="$(track_midi_notes 0)"
    if [ "$two_notes" = "$((base_notes + 2))" ]; then
        pass "two notes at different cells give baseline + 2"
    else
        fail "two notes at different cells give baseline + 2"
    fi

    if [ -n "$TRACK_COMBO_X" ] && [ -n "$TRACK_COMBO_Y" ]; then
        track1_notes="$(track_midi_notes 1)"
        # Opens the combo, moves down one item (track index 1), selects it.
        "$CLI" click "$TRACK_COMBO_X" "$TRACK_COMBO_Y" >/dev/null 2>&1 || fail "track combo opened"
        sleep 0.5
        "$CLI" key Down >/dev/null 2>&1 || fail "track combo: moved to track 1"
        "$CLI" key Return >/dev/null 2>&1 || fail "track combo: chose track 1"
        sleep 1
        if [ "$(track_midi_notes 0)" = "$((base_notes + 2))" ]; then
            pass "track 1 selected: track 0 still reports baseline + 2"
        else
            fail "track 1 selected: track 0 still reports baseline + 2"
        fi
        if [ "$(track_midi_notes 1)" = "$track1_notes" ]; then
            pass "track 1 midi_notes unchanged by track 0 edits"
        else
            fail "track 1 midi_notes unchanged by track 0 edits"
        fi

        # Back to track 0.
        "$CLI" click "$TRACK_COMBO_X" "$TRACK_COMBO_Y" >/dev/null 2>&1 || fail "track combo reopened"
        sleep 0.5
        "$CLI" key Up >/dev/null 2>&1 || fail "track combo: moved back to track 0"
        "$CLI" key Return >/dev/null 2>&1 || fail "track combo: chose track 0"
        sleep 1
        if [ "$(track_midi_notes 0)" = "$((base_notes + 2))" ]; then
            pass "back on track 0: reload keeps baseline + 2"
        else
            fail "back on track 0: reload keeps baseline + 2"
        fi
    else
        echo "  [SKIP] track combo switch: set TRACK_COMBO_X and TRACK_COMBO_Y to run it"
    fi

    before_key="$(track_midi_notes 0)"
    errors_before="$("$CLI" logs 500 2>/dev/null | grep -ci 'error' || true)"
    "$CLI" key a >/dev/null 2>&1 || fail "key a ran"
    sleep 1
    errors_after="$("$CLI" logs 500 2>/dev/null | grep -ci 'error' || true)"
    if [ "$errors_after" = "$errors_before" ] && [ "$(track_midi_notes 0)" = "$before_key" ]; then
        pass "key a plays without an app error and leaves midi_notes unchanged"
    else
        fail "key a plays without an app error and leaves midi_notes unchanged"
    fi

    before_mod="$(track_midi_notes 0)"
    "$CLI" key ctrl+a >/dev/null 2>&1 || fail "key ctrl+a ran"
    sleep 1
    if [ "$(track_midi_notes 0)" = "$before_mod" ]; then
        pass "ctrl+a does not change midi_notes"
    else
        fail "ctrl+a does not change midi_notes"
    fi
fi

echo "== artifacts"
if "$CLI" screenshot "$ARTIFACTS/final.png" >/dev/null 2>&1; then
    pass "screenshot saved to $ARTIFACTS/final.png"
else
    fail "screenshot saved"
fi
cp "$STATE_FILE" "$ARTIFACTS/state.json" 2>/dev/null || true

echo
echo "e2e: $PASSED passed, $FAILED failed"
[ "$FAILED" -eq 0 ]
