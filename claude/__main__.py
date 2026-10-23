"""Run McKay's barnaby app with every bear activity going through ONE queue (claude/activity.py).

A shown hand queues a dance (relay pulse + a canned PRETEXT yell); Gemini lines are queued
ahead of everything else. One activity at a time; a dance holds the bear for DANCE_S seconds.
Gemini scene talk is off unless --gemini is passed or you answer y at the startup prompt.
McKay's files are never edited: this module rebinds names on barnaby.app at runtime,
and no .pyc files are written into his src/.
Usage (from the repo root): PYTHONPATH=src python -m claude [--gemini] [barnaby flags...]
"""

import os
import random
import subprocess
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

CLAUDE_DIR = Path(__file__).resolve().parent
REPO = CLAUDE_DIR.parent
if str(REPO / "src") not in sys.path:
    sys.path.append(str(REPO / "src"))  # fallback if PYTHONPATH=src was forgotten
os.environ.setdefault("BEAR_DANCE_BIN", str(CLAUDE_DIR / "pi" / "dance_sda.sh"))

import barnaby.app  # noqa: E402  (McKay's, untouched)
from barnaby import speech  # noqa: E402

from claude.activity import ActivityWorker  # noqa: E402
from claude.voice import speak_wait  # noqa: E402

DANCE_S = float(os.environ.get("DANCE_S", "25"))  # > Try Me lock (~22 s, unmeasured): a dance never lands inside it
SPEAK_MAX_S = 30.0


def dance():
    binary = os.environ["BEAR_DANCE_BIN"]
    if not os.path.isfile(binary):
        print(f"DANCE (dry-run: {binary} not found)", file=sys.stderr, flush=True)
        return
    subprocess.Popen([binary])  # the relay blip returns at once; the bear dances on its own
    print(f"DANCE spawned ({binary})", file=sys.stderr, flush=True)


def run(item):
    """Runs one queued activity; blocks until it ends (the queue then holds for item.duration_s)."""
    if item.kind == "dance":
        dance()
        print(f"[yell] {item.payload}", file=sys.stderr, flush=True)
        speak_wait(speech, item.payload, SPEAK_MAX_S)
    elif item.kind == "gemini":
        speak_wait(speech, item.payload, SPEAK_MAX_S)
    elif item.kind == "cmd":  # e.g. a wheel move: [claude/hw/run_both, 5, 800, fwd]
        subprocess.run(item.payload, timeout=120)


activities = ActivityWorker(run)
_original = barnaby.app.on_perception


def on_perception(event):
    _original(event)
    try:
        if event.gesture != "none":  # any hand; repeats during a dance fall in its bucket
            activities.submit("dance", random.choice(PRETEXT), DANCE_S)
    except Exception as e:  # the vision loop must never die
        print(f"[queue error] {type(e).__name__}: {e}", file=sys.stderr, flush=True)


def on_scene_description(description):
    print(f"[Barnaby sees] {description}", flush=True)  # same line as McKay's; he would speak it now
    activities.submit("gemini", description, bucket=False)  # every line is new: no bucket


barnaby.app.on_perception = on_perception  # app.py calls the names it imported
barnaby.app.on_scene_description = on_scene_description

GEMINI_MAX = int(os.environ.get("GEMINI_MAX", "5"))  # Gemini calls per run; after that the bear just quacks
_describe_scene, _gemini_calls = barnaby.app.describe_scene, 0


def describe_scene(*args, **kwargs):
    global _gemini_calls
    if _gemini_calls >= GEMINI_MAX:
        return "Quack quack!"
    _gemini_calls += 1
    print(f"[gemini] call {_gemini_calls}/{GEMINI_MAX}", file=sys.stderr, flush=True)
    return _describe_scene(*args, **kwargs)


barnaby.app.describe_scene = describe_scene  # app.py submits the name it imported


def gemini_args(argv):
    """Strip --gemini; return (argv, extra flags) for this session's Gemini choice."""
    on = "--gemini" in argv
    argv = [a for a in argv if a != "--gemini"]
    if not on and "--check" not in argv and sys.stdin.isatty():
        on = input("Enable Gemini scene talk this session? [y/N] ").strip().lower() in ("y", "yes")
    if not on or any(a.startswith(("--scene", "--scene-model")) for a in argv):
        return argv, []
    return argv, ["--scene", "--scene-model", GEMINI_MODEL]


def main(argv=None):
    argv, extra = gemini_args(sys.argv[1:] if argv is None else list(argv))
    gemini = bool(extra) or "--scene" in argv
    print(f"yell: pretext + gemini ({GEMINI_MODEL})" if gemini else "yell: pretext", flush=True)
    barnaby.app.main(argv + extra)


if __name__ == "__main__":
    main()
