#!/bin/bash
# edge_test.sh [TESTNAME ...] — find WHICH contact edge/state of the "Try Me" pigtail makes the bear dance.
#
# Setup: relay module is active-HIGH (SIG HIGH = relay contact CLOSED = like pressing Try Me).
# Data so far: short close pulses (open -> close 0.3-3 s -> open) did NOT dance (maybe bad wiring);
# the SDA1 pattern (held closed -> open 0.3 s -> closed and held) danced 3/3; Tony remembers that
# touching the bare wires and pulling them apart danced on the RELEASE.
#
# Usage:  edge_test.sh                 # all tests, in order T1..T6
#         edge_test.sh hold_release T5 # selected tests (name or T-number), in the given order
# Env:    SIG=2     BCM pin driving the relay (default 2 = SDA1; its permanent pull-up means rest = CLOSED)
#         GAP=25    seconds between tests (Try Me lockout ~22 s); not scaled
#         DRY=1     no GPIO, no voice: print only ("(dry) close/open")
#         SCALE=1   multiplies every hold duration (tests use 0.01)
#         LOG=...   log file (default $T/edge_test.log, appended)
# Every edge prints "HH:MM:SS.mmm EDGE close|open" so "bear started at X" can be matched to an edge.
#
# Tests (each starts from a defined state held 3 s so a previous edge cannot leak in):
#   T1 tap               open(3s) -> CLOSE 0.3 s -> RELEASE, open 8 s
#   T2 hold_release      open(3s) -> CLOSE 5 s   -> RELEASE, open 8 s
#   T3 hold_only         open(3s) -> CLOSE, stay closed 10 s (no release)
#   T4 blip_open         closed(3s) -> RELEASE 0.3 s -> CLOSE, closed 8 s  (the SDA pattern that worked)
#   T5 release_only      closed(3s) -> RELEASE, open 10 s
#   T6 long_hold_release open(3s) -> CLOSE 10 s  -> RELEASE, open 8 s
#
# Hypothesis table (Y = predicts a dance, and at which edge). CLOSE = SIG rising, RELEASE = SIG falling.
#   test                | CLOSE edge (rising) | RELEASE edge (falling) | needs held closure (>~1 s)
#   T1 tap              | Y at CLOSE          | Y at RELEASE           | N
#   T2 hold_release     | Y at CLOSE          | Y at RELEASE           | Y during hold (or at RELEASE)
#   T3 hold_only        | Y at CLOSE          | N                      | Y during hold
#   T4 blip_open        | Y at re-CLOSE       | Y at RELEASE           | Y after re-CLOSE
#   T5 release_only     | N                   | Y at RELEASE           | N
#   T6 long_hold_release| Y at CLOSE          | Y at RELEASE           | Y during hold (or at RELEASE)
# Discriminators: T3 vs T5 (close-only vs release-only), T1 (short closure), T2/T6 timing (CLOSE vs RELEASE).
# Caveat: tests T4/T5 start CLOSED for 3 s; a "held closure" or CLOSE trigger may fire in that setup
# phase. Note it against the EDGE timestamps rather than counting it for the test.
#
# Safety: relay/SIG only. Wheels untouched, no camera. Never touches any pin other than $SIG;
# on exit/interrupt SIG returns to rest (SIG=2: input pull-up = closed; other pins: input pull-down = open).

SIG=${SIG:-2}
GAP=${GAP:-25}
SCALE=${SCALE:-1}
DRY=${DRY:-0}
DIR=$(cd "$(dirname "$0")" && pwd)
. "$DIR/env.sh"
LOG=${LOG:-$T/edge_test.log}
[ -x "$PY" ] || PY=python3

if ! [[ $SIG =~ ^[0-9]+$ ]] || [ "$SIG" -le 1 ] || [ "$SIG" -gt 27 ]; then
    echo "edge_test: refusing SIG=$SIG (must be BCM 2..27; 0/1 are the HAT EEPROM pins)" >&2; exit 2
fi
if ! [[ $SCALE =~ ^[0-9]*\.?[0-9]+$ ]] || ! [[ $GAP =~ ^[0-9]*\.?[0-9]+$ ]]; then
    echo "edge_test: SCALE and GAP must be non-negative numbers" >&2; exit 2
fi

ALL=(tap hold_release hold_only blip_open release_only long_hold_release)
TESTS=()
for a in "${@:-${ALL[@]}}"; do
    name=""
    for i in "${!ALL[@]}"; do
        if [ "$a" = "${ALL[$i]}" ] || [ "${a^^}" = "T$((i+1))" ]; then name=${ALL[$i]}; fi
    done
    [ -n "$name" ] || { echo "edge_test: unknown test '$a' (known: ${ALL[*]} or T1..T6)" >&2; exit 2; }
    TESTS+=("$name")
done

mkdir -p "$(dirname "$LOG")"
exec > >(tee -a "$LOG") 2>&1

ts() { date '+%T.%3N'; }
log() { echo "$(ts) $*"; }
say() { [ "$DRY" = 1 ] && return 0; (cd "$DIR" && "$PY" say.py "$@" 2>/dev/null) || true; }
banner() { echo; echo "=================================================================="; echo "  $*"; echo "=================================================================="; }
hold() { sleep "$(awk "BEGIN{print $1*$SCALE}")"; }
pin() { if [ "$DRY" = 1 ]; then echo "(dry) $1"; else pinctrl set "$SIG" "${@:2}"; fi; }
close() { pin close op dh; log "EDGE close"; }
open() { pin open op dl; log "EDGE open"; }
rest() {
    if [ "$DRY" = 1 ]; then echo "(dry) rest"
    elif [ "$SIG" = 2 ]; then pinctrl set 2 ip pu
    else pinctrl set "$SIG" ip pd; fi
}
trap 'rest' EXIT
trap 'echo; banner "INTERRUPTED: SIG $SIG back to rest"; exit 130' INT TERM

t_tap()               { open;  hold 3; close; hold 0.3; open;  hold 8; }
t_hold_release()      { open;  hold 3; close; hold 5;   open;  hold 8; }
t_hold_only()         { open;  hold 3; close; hold 10; }
t_blip_open()         { close; hold 3; open;  hold 0.3; close; hold 8; }
t_release_only()      { close; hold 3; open;  hold 10; }
t_long_hold_release() { open;  hold 3; close; hold 10;  open;  hold 8; }

declare -A WATCH=(
    [tap]="open 3 s, CLOSE 0.3 s, RELEASE. watch: dance at the tap at all?"
    [hold_release]="open 3 s, CLOSE 5 s, RELEASE. watch: does it start at CLOSE or at RELEASE?"
    [hold_only]="open 3 s, CLOSE and hold 10 s, no release. watch: dance at CLOSE or during the hold?"
    [blip_open]="closed 3 s, RELEASE 0.3 s, CLOSE and hold. watch: the SDA pattern; at RELEASE or re-CLOSE?"
    [release_only]="closed 3 s, RELEASE and stay open 10 s. watch: does RELEASE alone start it?"
    [long_hold_release]="open 3 s, CLOSE 10 s, RELEASE. watch: start at CLOSE, mid-hold, or RELEASE?"
)

total=${#TESTS[@]}
banner "EDGE TEST: $total tests on BCM$SIG (DRY=$DRY SCALE=$SCALE GAP=$GAP): ${TESTS[*]}"
say "Edge test. $total tests. Watch the bear."
i=0
for t in "${TESTS[@]}"; do
    i=$((i+1))
    banner "TEST $i of $total: $t. ${WATCH[$t]}"
    say "Test $i of $total. ${t//_/ }."
    "t_$t"
    log ">>> TEST $t DONE — dance? at which EDGE?"
    if [ "$i" -lt "$total" ]; then log "waiting ${GAP}s (Try Me lockout)"; sleep "$GAP"; fi
done
rest
if [ "$DRY" = 1 ]; then banner "EDGE TEST DONE (dry)"; else banner "EDGE TEST DONE: SIG $SIG $(pinctrl get "$SIG" | sed 's/.*| //')"; fi
say "Edge test done."
