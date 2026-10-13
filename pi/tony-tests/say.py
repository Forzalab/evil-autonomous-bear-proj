"""Speak argv text with McKay's Piper TTS (read-only import) and wait until playback has finished."""
import os, sys, time
sys.dont_write_bytecode = True
sys.path.insert(0, os.path.expanduser("~/Desktop/barnaby/evil-autonomous-bear-proj/src"))
os.environ["BARNABY_TTS"] = "1"
from barnaby import speech

speech.speak(" ".join(sys.argv[1:]))
w, deadline = speech._worker, time.time() + float(os.environ.get("SAY_MAX", "30"))
started = False
# Exiting early kills the speech (the worker stops at exit): wait for pw-play to start, then to finish.
while w is not None and time.time() < deadline:
    if w._playback is not None:
        started = True
    elif started or (not w._thread.is_alive()):
        break
    time.sleep(0.1)
