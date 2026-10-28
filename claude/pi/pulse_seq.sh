#!/bin/bash
# pulse_seq.sh [COUNTxMS[@GAP] ...] — sequential relay tests on BCM17 to find which pulses make the bear dance.
# Each test: banner + spoken "Test N of M" → pulse(s) via claude/hw/dance → wait GAP s (default 25, Try Me lockout ~22 s).
# COUNTxMS = COUNT pulses of MS ms, MS apart. @GAP = seconds to wait BEFORE this test. DRY=1 = no GPIO.
# Relay only: no wheels, no camera. Log: $T/pulse_seq.log
. "$(dirname "$0")/env.sh"
DANCE=$HW/dance
TESTS=(${@:-1x1500 1x1000 1x1200 1x2000 1x3000 2x300 3x500 1x1500 1x1500 1x1500@10})
exec > >(tee -a "$T/pulse_seq.log") 2>&1
log() { echo "$(date '+%T') $*"; }
say() { (cd "$PI" && "$PY" say.py "$@" 2>/dev/null) || true; }
banner() { echo; echo "=================================================================="; echo "  $*"; echo "=================================================================="; }
release() { pinctrl set 17 ip pd 2>/dev/null; }
trap 'echo; banner "INTERRUPTED: pin 17 back to input"; release; exit 130' INT TERM

total=${#TESTS[@]}
banner "PULSE SEQUENCE: $total tests on BCM17 (DRY=${DRY:-0}): ${TESTS[*]}"
say "Pulse sequence. $total tests. Watch the bear."
i=0
for t in "${TESTS[@]}"; do
    i=$((i+1))
    spec=${t%@*}; count=${spec%x*}; ms=${spec#*x}; gap=25
    [[ $t == *@* ]] && gap=${t#*@}
    [ $i -gt 1 ] && { log "waiting ${gap}s"; sleep "$gap"; }
    banner "TEST $i of $total: $count x ${ms} ms. WATCH THE BEAR."
    sec=$(awk "BEGIN{print $ms/1000}")
    if [ "$count" = 1 ]; then say "Test $i of $total. $sec seconds."; else say "Test $i of $total. $count pulses of $sec seconds."; fi
    sleep 1
    for p in $(seq "$count"); do
        [ $p -gt 1 ] && sleep "$(awk "BEGIN{print $ms/1000}")"
        if [ "${DRY:-0}" = 1 ]; then log "DRY pulse $p/$count ${ms}ms"; else "$DANCE" "$ms"; log "PULSE $p/$count ${ms}ms exit=$?"; fi
    done
    log ">>> TEST $i DONE ($count x ${ms} ms). Dance? note TEST $i"
done
release
banner "SEQUENCE DONE: pin 17 $(pinctrl get 17 | sed 's/.*| //')"
say "Sequence done."
