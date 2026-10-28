# env.sh — shared paths for claude/pi scripts. Source it: . "$(dirname "$0")/env.sh"
# One folder holds everything: BEAR_HOME (default = the folder above this checkout, e.g. ~/tony).
#   $REPO = this checkout, $PI = claude/pi, $HW = claude/hw binaries, $T = logs + flags (NO_BEAR, RUN_PIN_HUNT).
# Uninstall = delete the cron line + rm -rf "$BEAR_HOME".
PI=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO=$(cd "$PI/../.." && pwd)
BEAR_HOME=${BEAR_HOME:-$(dirname "$REPO")}
T=$BEAR_HOME/state
HW=$REPO/claude/hw
PY=${PY:-$REPO/.venv/bin/python}
export XDG_RUNTIME_DIR=${XDG_RUNTIME_DIR:-/run/user/$(id -u)}
mkdir -p "$T"
