#!/usr/bin/env bash
# Regression tests for the socket control path (docs/QA.md B11, B15, B16).
#
# Starts the headless app in a private XDG_RUNTIME_DIR (never touches a live
# session), drives it through the real `seridian` CLI and the raw socket, and
# kills only the pid it started.
#
# Usage: tests/e2e/control_regressions.sh [test-name ...]
#   tests: open_restores_bpm_and_master, relative_paths_are_absolute, one_command_per_request, single_instance, instruments_round_trip, reverb_from_the_cli, transport_replies, note_limits_agree
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
    trap - EXIT INT TERM
    if [ -n "$APP_PID" ] && kill -0 "$APP_PID" 2>/dev/null; then
        kill "$APP_PID" 2>/dev/null
        for _ in $(seq 1 50); do
            kill -0 "$APP_PID" 2>/dev/null || break
            sleep 0.1
        done
        if kill -0 "$APP_PID" 2>/dev/null; then kill -KILL "$APP_PID" 2>/dev/null; fi
        wait "$APP_PID" 2>/dev/null
    fi
    if [ -n "$WORK" ]; then rm -rf "$WORK"; fi
    if [ -n "$RUNTIME" ]; then rm -rf "$RUNTIME"; fi
}
trap cleanup EXIT
trap 'cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM

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
# Private config, data and cache too: the app autosaves a recovery copy under the
# config directory, and a leftover copy makes the next start wait on a recovery prompt.
export XDG_CONFIG_HOME="$WORK/config" XDG_DATA_HOME="$WORK/data" XDG_CACHE_HOME="$WORK/cache"
mkdir -p "$XDG_CONFIG_HOME" "$XDG_DATA_HOME" "$XDG_CACHE_HOME"

# The app's working directory is a directory of its own, so a path resolved in
# the app's directory is told apart from one resolved in the CLI's.
APP_CWD="$WORK/appcwd"
mkdir -p "$APP_CWD"
cd "$APP_CWD" && { "$APP" >"$WORK/app.log" 2>&1 & APP_PID=$!; }
cd "$ROOT" || exit 1

# Ready when the socket answers; the state file is not used for readiness.
READY=0
for _ in $(seq 1 100); do
    if [ "$("$CLI" bpm 120 2>/dev/null)" = "ok" ]; then READY=1; break; fi
    if ! kill -0 "$APP_PID" 2>/dev/null; then break; fi
    sleep 0.2
done
if [ "$READY" -ne 1 ]; then
    echo "app did not answer on the socket within 20s; log:"
    cat "$WORK/app.log"
    exit 1
fi

STATE="$RUNTIME/seridian-state.json"

state_field() { "$CLI" state >/dev/null 2>&1; jq -r "$1" "$STATE" 2>/dev/null; }

# Polls a numeric state field for up to 10 s until it is within 0.1 of the target.
# Prints the last value read; returns 0 when it matched.
wait_field() {
    local field="$1" target="$2" value=""
    for _ in $(seq 1 50); do
        value="$(state_field "$field")"
        if awk -v v="${value:-x}" -v t="$target" 'BEGIN { exit !(v + 0 > t - 0.1 && v + 0 < t + 0.1 && v != "x") }'; then
            echo "$value"; return 0
        fi
        sleep 0.2
    done
    echo "$value"; return 1
}

# Polls a state field for up to 10 s until it equals the text. Prints the last value read; returns 0 on a match.
wait_text() {
    local field="$1" target="$2" value=""
    for _ in $(seq 1 50); do
        value="$(state_field "$field")"
        if [ "$value" = "$target" ]; then echo "$value"; return 0; fi
        sleep 0.2
    done
    echo "$value"; return 1
}

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
    bpm="$(wait_field .bpm 90)"
    [ $? -eq 0 ] && pass "bpm restored to 90 (got $bpm)" || fail "bpm restored to 90 (got $bpm)"
    master="$(wait_field .master_gain 0.4)"
    [ $? -eq 0 ] && pass "master volume restored to 0.4 (got $master)" || fail "master volume restored to 0.4 (got $master)"
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
    bpm="$(wait_field .bpm 100)"
    [ $? -eq 0 ] && pass "no line of a rejected request ran (bpm $bpm)" || fail "no line of a rejected request ran (bpm $bpm)"
    reply="$(raw_send 'bpm 133\0junk\n')"
    case "$reply" in
        ok*) fail "an embedded NUL must not reply ok (got: $reply)" ;;
        *) pass "embedded NUL rejected (got: $reply)" ;;
    esac
}

# Counts live processes of this script's app binary that run with our private runtime dir.
count_apps() {
    local n=0 p
    for p in $(pgrep -f "$APP" 2>/dev/null); do
        if tr '\0' '\n' <"/proc/$p/environ" 2>/dev/null | grep -qx "XDG_RUNTIME_DIR=$RUNTIME"; then n=$((n + 1)); fi
    done
    echo "$n"
}

test_single_instance() {
    echo "== a second launch exits 0 with a message; a stale socket does not block start (U10)"
    local err="$WORK/second.err" status started
    local begin end
    begin=$(date +%s)
    timeout 10 "$APP" >"$WORK/second.out" 2>"$err"
    status=$?
    end=$(date +%s)
    [ "$status" -eq 0 ] && pass "second launch exits 0 (got $status)" || fail "second launch exits 0 (got $status)"
    [ $((end - begin)) -le 5 ] && pass "second launch returns quickly" || fail "second launch returns quickly ($((end - begin)) s)"
    grep -q "Seridian Studio is already running (pid $APP_PID)" "$err" && pass "message names the running pid" || fail "message names the running pid (got: $(cat "$err"))"
    [ "$(count_apps)" -eq 1 ] && pass "only one process remains" || fail "only one process remains (got $(count_apps))"
    [ "$("$CLI" bpm 120 2>/dev/null)" = "ok" ] && pass "first instance still answers" || fail "first instance still answers"

    # Kill the first without letting it clean up, so the socket file stays behind.
    kill -KILL "$APP_PID" 2>/dev/null
    wait "$APP_PID" 2>/dev/null
    [ -S "$RUNTIME/seridian.sock" ] && pass "stale socket file left behind" || fail "stale socket file left behind"
    cd "$APP_CWD" && { "$APP" >"$WORK/app2.log" 2>&1 & APP_PID=$!; }
    cd "$ROOT" || return
    started=0
    for _ in $(seq 1 100); do
        if [ "$("$CLI" bpm 120 2>/dev/null)" = "ok" ]; then started=1; break; fi
        kill -0 "$APP_PID" 2>/dev/null || break
        sleep 0.2
    done
    [ "$started" -eq 1 ] && pass "start over a stale socket answers on the socket" || fail "start over a stale socket answers on the socket (log: $(cat "$WORK/app2.log"))"
    [ "$(count_apps)" -eq 1 ] && pass "exactly one process after the restart" || fail "exactly one process after the restart (got $(count_apps))"
}

test_instruments_round_trip() {
    echo "== instruments listing, error text and set/state round trip (G5, B2, B5)"
    local names count name got reply
    names="$("$CLI" instruments)" || { fail "seridian instruments exits 0"; return; }
    count="$(printf '%s\n' "$names" | wc -l)"
    [ "$count" -eq 21 ] && pass "instruments prints 21 names" || fail "instruments prints 21 names (got $count)"
    while IFS= read -r name; do
        "$CLI" set 1 instrument "$name" >/dev/null 2>&1 || { fail "set accepts $name"; continue; }
        got="$(wait_text '.tracks[0].instrument' "$name")" && pass "state reports $name" || fail "state reports $name (got $got)"
    done <<<"$names"
    reply="$(raw_send 'set 2 instrument modelpiano\n')"
    [ "$reply" = "ok" ] && pass "raw set accepts modelpiano" || fail "raw set accepts modelpiano (got $reply)"
    got="$(wait_text '.tracks[1].instrument' ModelPiano)" && pass "state reports ModelPiano" || fail "state reports ModelPiano (got $got)"
    reply="$(raw_send 'set 2 instrument Nope\n')"
    local missing=0
    while IFS= read -r name; do
        case "$reply" in *"$name"*) ;; *) missing=$((missing + 1)) ;; esac
    done <<<"$names"
    [ "$missing" -eq 0 ] && pass "unknown-instrument error lists all names" || fail "unknown-instrument error misses $missing names (got $reply)"
}

test_reverb_from_the_cli() {
    echo "== reverb on, wet and off from the CLI; auto wet works afterwards (G1)"
    local out got
    out="$("$CLI" auto 1 wet 0 0.5 2>&1)" && fail "auto wet must fail before a reverb exists (got: $out)" || pass "auto wet refused without a reverb"
    "$CLI" set 1 reverb on >/dev/null 2>&1 && pass "set 1 reverb on" || fail "set 1 reverb on"
    got="$(wait_text '.tracks[0].reverb.present' true)" && pass "state reports the reverb present" || fail "state reports the reverb present (got $got)"
    "$CLI" set 1 reverb wet 0.4 >/dev/null 2>&1 && pass "set 1 reverb wet 0.4" || fail "set 1 reverb wet 0.4"
    got="$(wait_field '.tracks[0].reverb.wet' 0.4)" && pass "state reports wet 0.4" || fail "state reports wet 0.4 (got $got)"
    [ "$(state_field '.tracks[1].reverb.present')" = "false" ] && pass "other tracks have no reverb" || fail "other tracks have no reverb"
    "$CLI" auto 1 wet 0 0.1 >/dev/null 2>&1 && pass "auto 1 wet works without the UI" || fail "auto 1 wet works without the UI"
    out="$("$CLI" set 2 reverb wet 0.4 2>&1)" && fail "wet without a reverb must fail (got: $out)" || pass "wet without a reverb refused: $out"
    "$CLI" set 1 reverb off >/dev/null 2>&1 && pass "set 1 reverb off" || fail "set 1 reverb off"
    got="$(wait_text '.tracks[0].reverb.present' false)" && pass "state reports the reverb gone" || fail "state reports the reverb gone (got $got)"
}

test_transport_replies() {
    echo "== play and stop report the transport state and whether it changed (G3)"
    local out status
    "$CLI" stop >/dev/null 2>&1
    out="$("$CLI" play 2>&1)"; status=$?
    [ "$out" = "ok playing" ] && [ "$status" -eq 0 ] && pass "play prints 'ok playing', exit 0" || fail "play prints 'ok playing', exit 0 (got '$out', $status)"
    out="$("$CLI" play 2>&1)"; status=$?
    [ "$out" = "ok playing (already)" ] && [ "$status" -eq 0 ] && pass "second play prints 'ok playing (already)', exit 0" || fail "second play (got '$out', $status)"
    out="$("$CLI" stop 2>&1)"; status=$?
    [ "$out" = "ok stopped" ] && [ "$status" -eq 0 ] && pass "stop prints 'ok stopped', exit 0" || fail "stop prints 'ok stopped', exit 0 (got '$out', $status)"
    out="$("$CLI" stop 2>&1)"; status=$?
    [ "$out" = "ok stopped (already)" ] && [ "$status" -eq 0 ] && pass "second stop prints 'ok stopped (already)', exit 0" || fail "second stop (got '$out', $status)"
    out="$(raw_send 'play\n')"
    [ "$out" = "ok playing" ] && pass "raw play replies 'ok playing'" || fail "raw play replies 'ok playing' (got '$out')"
    "$CLI" stop >/dev/null 2>&1
}

test_note_limits_agree() {
    echo "== the CLI and the app agree on the largest note start and length (B3)"
    local reply out
    reply="$(raw_send 'note 1 60 1000001 1\n')"
    [ "$reply" = "error: start must be a number of beats 0..1000000" ] && pass "app rejects start 1000001 with the shared message" || fail "app start message (got '$reply')"
    reply="$(raw_send 'note 1 60 1e9 1\n')"
    [ "$reply" = "error: start must be a number of beats 0..1000000" ] && pass "app rejects start 1e9" || fail "app rejects start 1e9 (got '$reply')"
    reply="$(raw_send 'note 1 60 0 1000001\n')"
    [ "$reply" = "error: length must be a number of beats above 0 and up to 1000000" ] && pass "app rejects length 1000001 with the shared message" || fail "app length message (got '$reply')"
    out="$("$CLI" note 1 60 1e9 1 2>&1)" && fail "CLI rejects start 1e9" || pass "CLI rejects start 1e9 ($(printf '%s' "$out" | head -1))"
    reply="$(raw_send 'note 1 60 1000000 1 90\n')"
    [ "$reply" = "ok" ] && pass "app accepts start 1000000" || fail "app accepts start 1000000 (got '$reply')"
    "$CLI" note 2 60 1000000 1 90 >/dev/null 2>&1 && pass "CLI accepts start 1000000" || fail "CLI accepts start 1000000"
    "$CLI" clear 1 >/dev/null 2>&1; "$CLI" clear 2 >/dev/null 2>&1
}

ALL="open_restores_bpm_and_master relative_paths_are_absolute one_command_per_request single_instance instruments_round_trip reverb_from_the_cli transport_replies note_limits_agree"
SELECTED="${*:-$ALL}"
for name in $SELECTED; do
    "test_$name"
done

echo "passed: $PASSED, failed: $FAILED"
[ "$FAILED" -eq 0 ]
