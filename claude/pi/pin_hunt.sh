#!/bin/bash
# pin_hunt.sh [BCM pins...] — announce each test (screen + voice), pulse the pin 0.7 s, wait for a human to watch the bear.
# Phase 2 = wheels (skip with NO_WHEELS=1). Skips steppers 13 20 26 21, I2C 2 3, UART 14 15, SPI 7-11.
PY=~/Desktop/barnaby/evil-autonomous-bear-proj/.venv/bin/python
PINS=(${@:-17 27 22 4 18 23 24 25 5 6 12 16 19})
WHEEL_PINS=(13 20 26 21)
say() { (cd ~/tony-tests && "$PY" say.py "$@" 2>/dev/null) || true; }
banner() { echo; echo "=================================================================="; echo "  $*"; echo "=================================================================="; }
reset() { for p in "${PINS[@]}" "${WHEEL_PINS[@]}"; do gpio -g write $p 0 2>/dev/null; gpio -g mode $p in; done; }
trap 'echo; banner "INTERRUPTED: all pins reset to input"; reset; exit 130' INT TERM

total=${#PINS[@]}
banner "PHASE 1 of 2: RELAY PIN HUNT, $total pins: ${PINS[*]}"
say "Phase one. Relay pin hunt. $total pins."
i=0
for n in "${PINS[@]}"; do
    i=$((i+1))
    banner "PHASE 1, TEST $i of $total: PULSING BCM PIN $n (0.7 s). WATCH THE BEAR."
    say "Test $i of $total. Pin $n."
    sleep 1
    gpio -g mode $n out; gpio -g write $n 1; sleep 0.7; gpio -g write $n 0; gpio -g mode $n in
    echo ">>> PULSED $n. Did the bear react? Note: TEST $i = PIN $n"
    sleep 4
done
banner "PHASE 1 DONE: relay pin hunt finished"

if [ "$NO_WHEELS" != 1 ]; then
    banner "PHASE 2 of 2: WHEEL TEST, 3 runs of 200 steps. WHEELS IN AIR / OFF CART?"
    say "Phase two. Wheel test. Wheels in the air."
    sleep 3
    j=0
    while IFS='|' read -r label cue args; do
        j=$((j+1))
        banner "PHASE 2, TEST $j of 3: $label  (wheel_test $args)"
        say "Wheel test $j of 3. $cue"; sleep 1
        ~/tony-tests/wheel_test $args; echo ">>> WHEEL $args exit=$?"
        sleep 3
    done <<'SEQ'
WHEEL 1 FORWARD, STEP 13 / DIR 26|wheel one, step thirteen, dir twenty-six, forward|1 200 fwd
WHEEL 2 FORWARD, STEP 20 / DIR 21|wheel two, step twenty, dir twenty-one, forward|2 200 fwd
BOTH WHEELS BACK|both wheels, back|both 200 back
SEQ
    banner "PHASE 2 DONE: wheel test finished"
else
    banner "PHASE 2 SKIPPED (NO_WHEELS=1)"
fi
reset
banner "ALL TESTS DONE: every pin set back to input"
say "All tests done."
