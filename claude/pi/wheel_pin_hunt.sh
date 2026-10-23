#!/bin/bash
# wheel_pin_hunt.sh [pins...]            Phase 1: STEP signal on each pin, watch which wheel moves.
# wheel_pin_hunt.sh --dir STEP [pins...] Phase 2: known STEP pin; each candidate DIR held LOW then HIGH.
# DRY=1: no GPIO, no voice, just print. Never touches BCM 0, 1, 2. Every touched pin -> "ip pd" at the end / on trap.
. "$(dirname "$0")/env.sh"
LOG=${LOG:-$T/wheel_pin_hunt.log}
DEFAULT=(13 20 19 26 21 16 12 6 5 22 27 17 4 18 23 24 25 3 7 8 9 10 11 14 15)
declare -A PHYS=([3]=5 [4]=7 [5]=29 [6]=31 [7]=26 [8]=24 [9]=21 [10]=19 [11]=23 [12]=32 [13]=33 [14]=8
  [15]=10 [16]=36 [17]=11 [18]=12 [19]=35 [20]=38 [21]=40 [22]=15 [23]=16 [24]=18 [25]=22 [26]=37 [27]=13)

STEP=""
if [ "$1" = "--dir" ]; then STEP=$2; shift 2; fi
PINS=(${@:-${DEFAULT[@]}})
for p in "${PINS[@]}" $STEP; do
  [[ "$p" =~ ^[0-9]+$ ]] && [ -n "${PHYS[$p]}" ] || { echo "refused pin '$p': only BCM 3..27 (never 0, 1, 2)"; exit 2; }
done
if [ -n "$STEP" ]; then PINS=($(for p in "${PINS[@]}"; do [ "$p" != "$STEP" ] && echo $p; done)); fi
TOUCHED=()

log() { echo "$(date '+%F %T') $*" | tee -a "$LOG"; }
banner() { echo; echo "=================================================================="; echo "  $*"; echo "=================================================================="; log "$*"; }
say() {
  [ "$DRY" = 1 ] && { echo "(voice) $*"; return; }
  (cd "$PI" && "$PY" bear_voices.py say narrator "$*" >/dev/null 2>&1) || (cd "$PI" && "$PY" say.py "$*" >/dev/null 2>&1) || log "VOICE FAILED: $*"
}
reset() {
  [ "$DRY" = 1 ] && { echo "(dry) reset ${TOUCHED[*]} -> ip pd"; return; }
  for p in "${TOUCHED[@]}"; do [ "$p" -gt 2 ] && pinctrl set $p ip pd; done
}
burst() {  # burst <step> [dir level]
  TOUCHED+=($1 $2)
  if [ "$DRY" = 1 ]; then echo "(dry) step_pin $*"; else "$HW/step_pin" "$1" 600 800 $2 $3 2>&1 | tee -a "$LOG"; fi
  reset
}
trap 'echo; banner "INTERRUPTED: touched pins reset to ip pd"; reset; exit 130' INT TERM
trap 'reset' EXIT

echo "BCM -> physical header pin:"; for p in $(echo ${!PHYS[@]} | tr ' ' '\n' | sort -n); do printf "  BCM %2d = pin %2d\n" $p ${PHYS[$p]}; done
N=${#PINS[@]}
if [ -z "$STEP" ]; then
  banner "WHEEL STEP PIN HUNT${DRY:+ (DRY)}: $N pins: ${PINS[*]}"
  say "Wheel pin hunt. $N pins."
  i=0
  for p in "${PINS[@]}"; do
    i=$((i+1))
    banner "TEST $i of $N: STEP signal on BCM $p (physical pin ${PHYS[$p]})"
    say "Test $i. Pin $p. Watch the wheels."
    sleep 1; burst $p; log "PULSED $p"; sleep 3
  done
else
  banner "WHEEL DIR PIN HUNT${DRY:+ (DRY)}: STEP=BCM $STEP (pin ${PHYS[$STEP]}), $N DIR candidates: ${PINS[*]}"
  say "Direction hunt. Step pin $STEP. $N pins."
  i=0
  for p in "${PINS[@]}"; do
    i=$((i+1))
    for lv in 0 1; do
      w=$([ $lv = 0 ] && echo low || echo high)
      banner "TEST $i of $N: STEP BCM $STEP, DIR candidate BCM $p (physical pin ${PHYS[$p]}) held ${w^^}"
      say "Test $i. Pin $p $w."
      sleep 1; burst $STEP $p $lv; log "PULSED $STEP with DIR $p $w"; sleep 3
    done
  done
fi
reset
banner "WHEEL PIN HUNT DONE: touched pins reset to ip pd"
say "Wheel pin hunt done."
