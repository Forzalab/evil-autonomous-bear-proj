"""Run McKay's barnaby app with the dance bridge wrapped around on_perception.

On each dance fire (live or dry-run) the bear yells a canned PRETEXT line through McKay's TTS.
Gemini scene talk is off unless --gemini is passed or you answer y at the startup prompt.
McKay's files are never edited: this module rebinds names on barnaby.app at runtime,
and no .pyc files are written into his src/.
Usage (from the repo root): PYTHONPATH=src python -m claude [--gemini] [barnaby flags...]
"""

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

CLAUDE_DIR = Path(__file__).resolve().parent
REPO = CLAUDE_DIR.parent
if str(REPO / "src") not in sys.path:
    sys.path.append(str(REPO / "src"))  # fallback if PYTHONPATH=src was forgotten
os.environ.setdefault("BEAR_DANCE_BIN", str(CLAUDE_DIR / "pi" / "dance_sda.sh"))

import barnaby.app  # noqa: E402  (McKay's, untouched)
from barnaby import speech  # noqa: E402

from claude import bridge  # noqa: E402

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
