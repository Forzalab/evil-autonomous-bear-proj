"""Run McKay's barnaby app with the tony-bear dance bridge wrapped around on_perception.

On each dance fire (live or dry-run) the bear yells a canned PRETEXT line through McKay's TTS.
Gemini scene talk is off unless --gemini is passed or you answer y at the startup prompt.
McKay's checkout is read-only here: nothing is edited, and no .pyc files are written into it.
Usage (from McKay's repo): .venv/bin/python ~/tony-tests/dance_launch.py [--gemini] [barnaby flags...]
"""

import importlib.util
import os
import random
import sys
from pathlib import Path

sys.dont_write_bytecode = True  # keep McKay's src free of new __pycache__ files

PRETEXT = [
    "I see you, tiny human.",
    "Dance with me or perish!",
    "Your snacks belong to Barnaby now.",
    "Nobody escapes the dance floor of doom!",
    "Wave all you like, my gears are already turning.",
    "Barnaby the bear is watching you.",
    "Shake it, human, or face my fuzzy wrath!",
]
GEMINI_MODEL = "gemini-3.5-flash-lite"

HOME = Path.home()
MCKAY_SRC = HOME / "Desktop/barnaby/evil-autonomous-bear-proj/src"
TONY_SRC = HOME / "tony-bear/src"

sys.path.insert(0, str(MCKAY_SRC))  # barnaby = McKay's (TTS + Gemini)
sys.path.append(str(TONY_SRC))      # bear_decider = tony-bear's
os.environ.setdefault("BEAR_DANCE_BIN", str(HOME / "tony-bear/pi/dance"))

# McKay's barnaby has no trigger.py; graft tony-bear's in under barnaby's name.
import barnaby  # noqa: E402

spec = importlib.util.spec_from_file_location("barnaby.trigger", TONY_SRC / "barnaby/trigger.py")
trigger = importlib.util.module_from_spec(spec)
sys.modules["barnaby.trigger"] = trigger
spec.loader.exec_module(trigger)

import barnaby.app  # noqa: E402
from barnaby import speech  # noqa: E402
from bear_decider import bridge  # noqa: E402

bridge._bridge = bridge.DanceBridge(stream=sys.stderr)  # shared bridge; built here so we can see fires
_original = barnaby.app.on_perception


def yell(text):
    try:
        print(f"[yell] {text}", file=sys.stderr, flush=True)
        speech.speak(text)  # non-blocking: queues to McKay's SpeechWorker (needs BARNABY_TTS=1)
    except Exception as e:
        print(f"[yell error] {type(e).__name__}: {e}", file=sys.stderr, flush=True)


def on_perception(event):
    _original(event)
    try:
        before = bridge._bridge.trigger._fired_at
        if bridge.handle(event):
            print(f"DANCE spawned ({os.environ['BEAR_DANCE_BIN']})", file=sys.stderr, flush=True)
        if bridge._bridge.trigger._fired_at != before:  # fired, live or dry-run
            yell(random.choice(PRETEXT))
    except Exception as e:  # the vision loop must never die
        print(f"[dance bridge error] {type(e).__name__}: {e}", file=sys.stderr, flush=True)


barnaby.app.on_perception = on_perception  # app.py calls the name it imported


def gemini_args(argv):
    """Strip --gemini; return (argv, extra flags) for this session's Gemini choice."""
    on = "--gemini" in argv
    argv = [a for a in argv if a != "--gemini"]
    if not on and "--check" not in argv and sys.stdin.isatty():
        on = input("Enable Gemini scene talk this session? [y/N] ").strip().lower() in ("y", "yes")
    if not on or any(a.startswith(("--scene", "--scene-model")) for a in argv):
        return argv, []
    return argv, ["--scene", "--scene-model", GEMINI_MODEL]


if __name__ == "__main__":
    argv, extra = gemini_args(sys.argv[1:])
    gemini = bool(extra) or "--scene" in argv
    print(f"yell: pretext + gemini ({GEMINI_MODEL})" if gemini else "yell: pretext", flush=True)
    barnaby.app.main(argv + extra)
