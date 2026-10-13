#!/bin/bash
# bear_loop.sh — keep the bear detection running forever: camera → hand → dance (SDA1) + yell. Restarts on crash.
# Started by boot.sh. Gemini is OFF (stdin is /dev/null, so `python -m claude` never prompts).
# Runs `python -u -m claude` from REPO (a checkout that has the claude/ folder next to McKay's src/).
# Stop:  touch ~/tony-tests/NO_BEAR ; pkill -f 'python -u -m claude'    Resume: rm ~/tony-tests/NO_BEAR, run this script.
T=/home/spauly/tony-tests
REPO=/home/spauly/Desktop/barnaby/evil-autonomous-bear-proj
export HOME=/home/spauly XDG_RUNTIME_DIR=/run/user/1000 WAYLAND_DISPLAY=wayland-0 DISPLAY=:0
export BEAR_DANCE_BIN=$REPO/claude/pi/dance_sda.sh PYTHONPATH=$REPO/src
exec >>"$T/bear_loop.log" 2>&1
log() { echo "$(date '+%F %T') $*"; }
cd "$REPO" || exit 1
while [ ! -e "$T/NO_BEAR" ]; do
    for i in $(seq 60); do [ -e /dev/video0 ] && break; sleep 1; done
    [ -e /dev/video0 ] || { log "no webcam (/dev/video0), retry in 30 s"; sleep 30; continue; }
    ui=(); [ -S /run/user/1000/wayland-0 ] || ui=(--headless)   # window when a desktop exists, else headless
    log "start bear detection ${ui[*]:-with window}"
    .venv/bin/python -u -m claude --source 0 "${ui[@]}" </dev/null >/dev/null   # stderr (dances, yells, errors) → log
    log "bear detection exited ($?), restart in 5 s"
    sleep 5
done
log "NO_BEAR set, loop stopped"
